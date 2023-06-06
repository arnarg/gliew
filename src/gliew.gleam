import gleam/int
import gleam/string
import gleam/list
import gleam/map.{Map}
import gleam/result
import gleam/crypto
import gleam/option.{None, Option, Some}
import gleam/uri
import gleam/bit_builder
import gleam/otp/actor
import gleam/erlang/process.{Selector, Subject}
import gleam/http.{Get}
import gleam/http/request.{Request}
import gleam/http/response
import mist.{Body}
import mist/websocket
import mist/internal/websocket.{TextMessage} as iwebsocket
import glisten
import glisten/handler.{HandlerMessage}
import nakai
import nakai/html
import nakai/html/attrs

const sess_id_prefix = "gliew-"

const csrf_prefix = "g-"

const elem_id_prefix = "g-"

// Event is a special type that can be added to attributes
// in HTML tree elements.
// That way we can just return a HTML tree of `html.Node(Event)`
// and later walk the tree to extract various data from it.
//
pub opaque type Event {
  // Instructs that the HTML node is the root of a mount
  // and contains the selector function for the worker
  // to know how to process updates.
  Mount(selecting: fn(Selector(WorkerMessage)) -> Selector(WorkerMessage))
}

/// Creates a HTML node tree that will be `mounted`
/// and receive live updates with data on `Subject(a)`
/// returned by the mount function.
///
pub fn mount(
  mount mount: fn(b) -> Subject(a),
  with context: b,
  render render: fn(Option(a)) -> html.Node(Event),
) {
  // Render initial node tree
  let tree =
    render(None)
    |> process_tree(None)

  // Get id from root element
  let id = extract_id(tree)

  // Add mount event to root of tree
  fn(selector: Selector(WorkerMessage)) {
    // Mount component to get subject
    let subject = mount(context)

    // Select and map subject
    selector
    |> process.selecting(
      subject,
      fn(val) {
        render(Some(val))
        |> process_tree(Some(id))
        |> nakai.to_inline_string
        |> LiveUpdate
      },
    )
  }
  |> Mount
  |> insert_event(tree)
}

// Insert the event to the node.
//
fn insert_event(event: Event, node: html.Node(Event)) {
  case node {
    html.Element(tag, attrs, children) ->
      attrs
      |> list.prepend(attrs.Event("gliew-event", event))
      |> html.Element(tag, _, children)
    html.LeafElement(tag, attrs) ->
      attrs
      |> list.prepend(attrs.Event("gliew-event", event))
      |> html.LeafElement(tag, _)
    other -> other
  }
}

// Adds the id attribute to the node if provided, otherwise
// generates it.
//
fn process_tree(node: html.Node(Event), id: Option(String)) {
  case node {
    html.Element(tag, attrs, children) ->
      attrs
      |> ensure_id(id)
      |> html.Element(tag, _, children)
    html.LeafElement(tag, attrs) ->
      attrs
      |> ensure_id(id)
      |> html.LeafElement(tag, _)
    other -> other
  }
}

// Make sure there is an id attribute in the list of attributes.
// If id is `None` it will generate one if there isn't one.
// If id is `Some(id)` it will replace any id if there is one or
// otherwise add it.
//
fn ensure_id(attrs: List(attrs.Attr(Event)), id: Option(String)) {
  case has_id(attrs) {
    True ->
      case id {
        Some(id) ->
          list.map(
            attrs,
            fn(attr) {
              case attr {
                attrs.Attr("id", _) -> attrs.id(id)
                other -> other
              }
            },
          )
        None -> attrs
      }
    False ->
      attrs
      |> list.prepend(attrs.id(
        id
        |> option.unwrap(random_id()),
      ))
  }
}

// Extract the ID value from a HTML node.
//
fn extract_id(node: html.Node(Event)) {
  case node {
    html.Element(_, attrs, _) -> find_id(attrs)
    html.LeafElement(_, attrs) -> find_id(attrs)
    _ -> Error(Nil)
  }
  |> result.unwrap(random_id())
}

// Find id attribute in a list of attrs.
//
fn find_id(attrs: List(attrs.Attr(Event))) {
  attrs
  |> list.find_map(fn(attr) {
    case attr {
      attrs.Attr("id", id) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

// Generates a random ID for a HTML id attribute.
//
fn random_id() {
  elem_id_prefix <> random_string(3)
}

// Check if list of attrs has id.
//
fn has_id(attrs: List(attrs.Attr(a))) {
  attrs
  |> list.any(fn(a) {
    case a {
      attrs.Attr("id", _) -> True
      _ -> False
    }
  })
}

// Manager -----------------------------------------------

type LoopState {
  LoopState(sessions: Map(String, Session))
}

type Session {
  Session(
    id: String,
    csrf: String,
    selects: List(fn(Selector(WorkerMessage)) -> Selector(WorkerMessage)),
    tree: html.Node(Event),
  )
}

type Message {
  RenderTree(
    from: Subject(String),
    request: Request(Body),
    tree: html.Node(Event),
  )
  CheckConnect(from: Subject(Bool), id: String, csrf: String)
  DoConnect(id: String, socket: Subject(HandlerMessage))
}

fn start_manager() {
  actor.start(LoopState(sessions: map.new()), loop)
}

fn loop(message: Message, state: LoopState) -> actor.Next(LoopState) {
  case message {
    // Render tree
    RenderTree(from, _, tree) ->
      case extract_selects([], tree) {
        // Regular static view
        [] -> {
          process.send(
            from,
            tree
            |> nakai.to_inline_string,
          )

          actor.Continue(state)
        }
        selects -> {
          // Create a session ID
          let sess_id = sess_id_prefix <> random_string(10)
          // Create a CSRF token
          let csrf = csrf_prefix <> random_string(24)

          process.send(
            from,
            tree
            |> nakai.to_inline_string
            |> wrap_live_view(sess_id, csrf),
          )

          actor.Continue(LoopState(
            sessions: state.sessions
            |> map.insert(sess_id, Session(sess_id, csrf, selects, tree)),
          ))
        }
      }

    // Check if session is active
    CheckConnect(from, id, csrf) -> {
      case
        state.sessions
        |> map.get(id)
      {
        Ok(sess) -> process.send(from, sess.csrf == csrf)
        Error(Nil) -> process.send(from, False)
      }
      actor.Continue(state)
    }

    // Start a connection worker
    DoConnect(id, socket) -> {
      // TODO: handle gracefully
      case
        state.sessions
        |> map.get(id)
      {
        Ok(sess) -> {
          let _ = start_worker(socket, sess.selects, sess.tree)
          Nil
        }
        Error(Nil) -> Nil
      }

      actor.Continue(state)
    }
  }
}

// Walks the node tree until it finds a `Mount` event and adds
// its select function to the list of of all select functions
// in the tree.
//
fn extract_selects(
  selects: List(fn(Selector(WorkerMessage)) -> Selector(WorkerMessage)),
  node: html.Node(Event),
) {
  case node {
    html.Element(_, attrs, children) ->
      case extract_event(attrs) {
        Ok(Mount(selector)) ->
          selects
          |> list.prepend(selector)
        Error(Nil) ->
          children
          |> list.fold(selects, extract_selects)
      }
    html.LeafElement(_, attrs) ->
      case extract_event(attrs) {
        Ok(Mount(selector)) ->
          selects
          |> list.prepend(selector)
        Error(Nil) -> selects
      }
    _ -> selects
  }
}

// Extract a single gliew event attribute.
//
fn extract_event(attrs: List(attrs.Attr(Event))) {
  attrs
  |> list.find_map(fn(attr) {
    case attr {
      attrs.Event("gliew-event", event) -> Ok(event)
      _ -> Error(Nil)
    }
  })
}

// Wrap a container around a node tree containing any
// live mounts inside.
// This instructs htmx to make a websocket connection back
// to the server.
//
fn wrap_live_view(markup: String, session_id: String, csrf: String) {
  html.div(
    [
      attrs.Attr("hx-ext", "ws"),
      attrs.Attr(
        "ws-connect",
        "/connect?session=" <> session_id <> "&csrf=" <> csrf,
      ),
      attrs.Attr("hx-ext", "morph"),
    ],
    [html.UnsafeText(markup)],
  )
  |> nakai.to_string
}

fn render_tree(
  subject: Subject(Message),
  request: Request(Body),
  tree: html.Node(Event),
) {
  process.call(subject, RenderTree(_, request, tree), 1000)
}

fn check_connect(subject: Subject(Message), id: String, csrf: String) {
  process.call(subject, CheckConnect(_, id, csrf), 1000)
}

fn do_connect(
  subject: Subject(Message),
  id: String,
  socket: Subject(HandlerMessage),
) {
  process.send(subject, DoConnect(id, socket))
}

fn to_hex_string(bstr: BitString) {
  case bstr {
    <<>> -> ""
    <<a:8, rest:bit_string>> -> {
      int.to_base16(a)
      |> string.lowercase <> to_hex_string(rest)
    }
  }
}

fn random_string(len: Int) {
  crypto.strong_random_bytes(len)
  |> to_hex_string
}

// Worker ------------------------------------------------

type WorkerState {
  WorkerState(socket: Subject(HandlerMessage), tree: html.Node(Event))
}

type WorkerMessage {
  LiveUpdate(markup: String)
}

fn start_worker(
  socket: Subject(HandlerMessage),
  selects: List(fn(Selector(WorkerMessage)) -> Selector(WorkerMessage)),
  tree: html.Node(Event),
) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let selector =
        process.new_selector()
        |> apply_selects(selects)

      actor.Ready(WorkerState(socket, tree), selector)
    },
    init_timeout: 1000,
    loop: worker_loop,
  ))
}

fn worker_loop(msg: WorkerMessage, state: WorkerState) {
  case msg {
    LiveUpdate(markup) -> {
      // Send updated markup to websocket
      websocket.send(state.socket, TextMessage(markup))

      actor.Continue(state)
    }
  }
}

fn apply_selects(
  selector: Selector(WorkerMessage),
  selects: List(fn(Selector(WorkerMessage)) -> Selector(WorkerMessage)),
) {
  selector
  |> list.fold(selects, _, fn(selector, selecting) { selecting(selector) })
}

// Server ------------------------------------------------

pub fn serve(port: Int, handler: fn(Request(Body)) -> html.Node(Event)) {
  use manager <- result.try(
    start_manager()
    |> result.map_error(fn(err) {
      case err {
        actor.InitTimeout -> glisten.AcceptorTimeout
        actor.InitFailed(reason) -> glisten.AcceptorFailed(reason)
        actor.InitCrashed(any) -> glisten.AcceptorCrashed(any)
      }
    }),
  )

  mist.serve(port, handler_func(manager, handler))
}

fn handler_func(
  manager: Subject(Message),
  handler: fn(Request(Body)) -> html.Node(Event),
) {
  // Return actual handler func
  fn(req: Request(Body)) {
    case req.method, req.path {
      Get, "/connect" -> handle_ws_connect(manager, req)
      _, _ -> {
        let view = handler(req)

        let body =
          html.Html(
            [],
            [
              html.Head([
                html.Element(
                  tag: "script",
                  attrs: [
                    attrs.src(
                      "https://unpkg.com/htmx.org@1.9.2/dist/htmx.min.js",
                    ),
                  ],
                  children: [],
                ),
                html.Element(
                  tag: "script",
                  attrs: [
                    attrs.src("https://unpkg.com/htmx.org@1.9.2/dist/ext/ws.js"),
                  ],
                  children: [],
                ),
                html.Element(
                  tag: "script",
                  attrs: [
                    attrs.src(
                      "https://unpkg.com/idiomorph@0.0.8/dist/idiomorph-ext.min.js",
                    ),
                  ],
                  children: [],
                ),
              ]),
              html.Body(
                attrs: [],
                children: [html.UnsafeText(render_tree(manager, req, view))],
              ),
            ],
          )
          |> nakai.to_string

        response.new(200)
        |> mist.bit_builder_response(bit_builder.from_string(body))
      }
    }
  }
  |> mist.handler_func
}

fn handle_ws_connect(manager: Subject(Message), req: Request(Body)) {
  case parse_params(req) {
    Ok(#(id, csrf)) -> upgrade_connection(manager, id, csrf)
    Error(Nil) ->
      response.new(401)
      |> mist.empty_response
  }
}

fn upgrade_connection(manager: Subject(Message), session: String, csrf: String) {
  case check_connect(manager, session, csrf) {
    False ->
      response.new(401)
      |> mist.empty_response
    True -> {
      fn(_msg, _subject: Subject(HandlerMessage)) { Ok(Nil) }
      |> websocket.with_handler
      |> websocket.on_init(fn(subject: Subject(HandlerMessage)) {
        do_connect(manager, session, subject)
      })
      |> mist.upgrade
    }
  }
}

fn parse_params(req: Request(Body)) {
  case req.query {
    Some(params) ->
      case uri.parse_query(params) {
        Ok(params) ->
          list.map(
            params,
            fn(p) {
              #(
                p.0,
                p.1
                |> string.replace(" ", "+"),
              )
            },
          )
          |> get_params
        Error(Nil) -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

fn get_params(params: List(#(String, String))) {
  let pmap = map.from_list(params)

  use session <- result.then(map.get(pmap, "session"))
  use csrf <- result.then(map.get(pmap, "csrf"))

  Ok(#(session, csrf))
}
