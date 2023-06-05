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
import gleam/erlang/process.{Subject}
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

pub opaque type View(a, b) {
  View(render: fn() -> String)
  LiveView(
    context: b,
    mount: fn(b) -> Assign(a),
    render: fn(String, Option(a)) -> String,
  )
}

/// Creates a static view that is only rendered on
/// the initial request.
///
pub fn view(render: fn() -> html.Node(a)) {
  fn() {
    render()
    |> nakai.to_inline_string
  }
  |> View
}

/// Creates a live updating view that will be kept
/// in sync on the client after it connects back
/// to the server.
///
pub fn live_view(
  mount mount: fn(b) -> Assign(a),
  with context: b,
  render render: fn(Option(a)) -> html.Node(c),
) {
  LiveView(context, mount, wrap_render(render))
}

// This is used to a inject an id to the root of the
// view markup, if not present already.
//
fn wrap_render(render: fn(Option(a)) -> html.Node(b)) {
  fn(id: String, param: Option(a)) {
    case render(param) {
      html.Element(tag, attrs, children) ->
        case has_id(attrs) {
          True -> attrs
          False ->
            attrs
            |> list.prepend(attrs.id(id))
        }
        |> list.prepend(attrs.Attr("hx-swap-oob", "morph"))
        |> html.Element(tag, _, children)
      other -> other
    }
    |> nakai.to_inline_string
  }
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

pub opaque type Assign(a) {
  Assign(subject: Subject(a), unsubscribe: Option(fn() -> Nil))
}

/// Create an assign with a subject that will get new data.
///
pub fn assign(subject: Subject(a)) {
  Assign(subject, None)
}

/// Add an unsubscribe function that will be called when the session
/// worker exits.
///
pub fn unsubscribe(assign: Assign(a), with unsub: fn(Subject(a)) -> Nil) {
  Assign(..assign, unsubscribe: Some(fn() { unsub(assign.subject) }))
}

// Manager -----------------------------------------------

type LoopState(a, b) {
  LoopState(sessions: Map(String, Session(a, b)))
}

type Session(a, b) {
  Session(session_id: String, csrf: String, id: String, view: View(a, b))
}

type Message(a, b) {
  RenderView(from: Subject(String), request: Request(Body), view: View(a, b))
  CheckConnect(from: Subject(Bool), id: String, csrf: String)
  DoConnect(id: String, socket: Subject(HandlerMessage))
}

fn start_manager() {
  actor.start(LoopState(sessions: map.new()), loop)
}

fn loop(
  message: Message(a, b),
  state: LoopState(a, b),
) -> actor.Next(LoopState(a, b)) {
  case message {
    // Render a regular view
    RenderView(from, _, View(render)) -> {
      process.send(from, render())

      actor.Continue(state)
    }
    // Render a live view
    RenderView(from, _, LiveView(context, mount, render)) -> {
      // Create a session ID
      let sess_id = "gliew-" <> random_string(10)

      // Create a CSRF token
      let csrf = "g-" <> random_string(24)

      // Create an id attr for the view.
      let id = "g-" <> random_string(4)

      process.send(
        from,
        render(id, None)
        |> wrap_live_view(sess_id, csrf),
      )

      actor.Continue(LoopState(
        sessions: state.sessions
        |> map.insert(
          sess_id,
          Session(sess_id, csrf, id, LiveView(context, mount, render)),
        ),
      ))
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
          let _ = start_worker(sess.id, socket, sess.view)
          Nil
        }
        Error(Nil) -> Nil
      }

      actor.Continue(state)
    }
  }
}

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

fn render_view(
  subject: Subject(Message(a, b)),
  request: Request(Body),
  view: View(a, b),
) {
  process.call(subject, RenderView(_, request, view), 1000)
}

fn check_connect(subject: Subject(Message(a, b)), id: String, csrf: String) {
  process.call(subject, CheckConnect(_, id, csrf), 1000)
}

fn do_connect(
  subject: Subject(Message(a, b)),
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

type WorkerState(a) {
  WorkerState(
    id: String,
    socket: Subject(HandlerMessage),
    subject: Subject(a),
    render: fn(String, Option(a)) -> String,
    on_close: fn() -> Nil,
  )
}

type WorkerMessage(a) {
  NewData(data: a)
}

fn start_worker(id: String, socket: Subject(HandlerMessage), view: View(a, b)) {
  actor.start_spec(actor.Spec(
    init: fn() {
      case view {
        View(_) -> actor.Failed("not live view")
        LiveView(context, mount, render) -> {
          // Call mount for the live view.
          let assign = mount(context)

          // Create a mapping selector for live view's subject.
          let selector =
            process.new_selector()
            |> process.selecting(assign.subject, fn(data) { NewData(data) })

          actor.Ready(
            WorkerState(
              id,
              socket,
              assign.subject,
              render,
              assign.unsubscribe
              |> option.unwrap(fn() { Nil }),
            ),
            selector,
          )
        }
      }
    },
    init_timeout: 1000,
    loop: worker_loop,
  ))
}

fn worker_loop(msg: WorkerMessage(a), state: WorkerState(a)) {
  case msg {
    NewData(data) -> {
      // Send rendered view to websocket.
      websocket.send(
        state.socket,
        TextMessage(state.render(state.id, Some(data))),
      )

      actor.Continue(state)
    }
  }
}

// Server ------------------------------------------------

pub fn serve(port: Int, handler: fn(Request(Body)) -> View(a, b)) {
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
  manager: Subject(Message(a, b)),
  handler: fn(Request(Body)) -> View(a, b),
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
                      "https://unpkg.com/idiomorph/dist/idiomorph-ext.min.js",
                    ),
                  ],
                  children: [],
                ),
              ]),
              html.Body(
                attrs: [],
                children: [html.UnsafeText(render_view(manager, req, view))],
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

fn handle_ws_connect(manager: Subject(Message(a, b)), req: Request(Body)) {
  case parse_params(req) {
    Ok(#(id, csrf)) -> upgrade_connection(manager, id, csrf)
    Error(Nil) ->
      response.new(401)
      |> mist.empty_response
  }
}

fn upgrade_connection(
  manager: Subject(Message(a, b)),
  session: String,
  csrf: String,
) {
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
