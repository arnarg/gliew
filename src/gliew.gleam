import gleam/io
import gleam/string
import gleam/list
import gleam/map.{Map}
import gleam/result
import gleam/base
import gleam/crypto
import gleam/option.{None, Option}
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

pub type Component(a) {
  Component(render: fn(Request(Body)) -> html.Node(Component(a)))
  LiveComponent(
    mount: fn() -> Nil,
    render: fn(Request(Body), Option(a)) -> html.Node(Component(a)),
  )
}

pub fn component(render: fn(Request(Body)) -> html.Node(Component(a))) {
  Component(render)
}

pub fn live_component(
  mount: fn() -> Nil,
  render: fn(Request(Body), Option(a)) -> html.Node(Component(a)),
) {
  LiveComponent(mount, render)
}

// Manager -----------------------------------------------

type LoopState(a) {
  LoopState(sessions: Map(String, Component(a)))
}

type Message(a) {
  RenderComponent(
    from: Subject(html.Node(Component(a))),
    request: Request(Body),
    component: Component(a),
  )
}

fn start_manager() {
  actor.start(LoopState(sessions: map.new()), loop)
}

fn loop(message: Message(a), state: LoopState(a)) -> actor.Next(LoopState(a)) {
  case message {
    // Render a regular component
    RenderComponent(from, req, Component(render)) -> {
      process.send(from, render(req))

      actor.Continue(state)
    }
    // Render a live component
    RenderComponent(from, req, LiveComponent(mount, render)) -> {
      // Create a session ID
      let sess_id = "gliew-" <> random_string(10)

      // Create a CSRD token
      let csrf = "g-" <> random_string(24)

      process.send(
        from,
        render(req, None)
        |> process_live_component(sess_id, csrf),
      )

      actor.Continue(LoopState(
        sessions: state.sessions
        |> map.insert(sess_id, LiveComponent(mount, render)),
      ))
    }
  }
}

fn process_live_component(node: html.Node(a), session_id: String, csrf: String) {
  case node {
    html.Element(tag, attrs, children) ->
      attrs
      |> list.prepend(attrs.Attr(
        "ws-connect",
        "/connect?session=" <> session_id <> "&csrf=" <> csrf,
      ))
      |> list.prepend(attrs.Attr("hx-ext", "ws"))
      |> html.Element(tag, _, children)
    node -> node
  }
}

fn render_component(
  subject: Subject(Message(a)),
  request: Request(Body),
  component: Component(a),
) {
  process.call(subject, RenderComponent(_, request, component), 1000)
}

fn random_string(len: Int) {
  crypto.strong_random_bytes(len)
  |> base.encode64(False)
}

// Server ------------------------------------------------

pub fn serve(port: Int, handler: fn(Request(Body)) -> Component(a)) {
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
  manager: Subject(Message(a)),
  handler: fn(Request(Body)) -> Component(a),
) {
  // Return actual handler func
  fn(req: Request(Body)) {
    case req.method, req.path {
      Get, "/connect" -> handle_ws_connect(manager, req)
      _, _ -> {
        let component = handler(req)

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
              ]),
              html.Body(
                attrs: [],
                children: [render_component(manager, req, component)],
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

fn handle_ws_connect(_manager: Subject(Message(a)), request: Request(Body)) {
  fn(msg, _subject: Subject(HandlerMessage)) {
    io.debug(msg)
    Ok(Nil)
  }
  |> websocket.with_handler
  |> websocket.on_init(fn(subject: Subject(HandlerMessage)) {
    io.debug(request)
    io.println("on_init: " <> string.inspect(subject))

    process.sleep(1000)

    websocket.send(
      subject,
      TextMessage("<div id=\"placeholder\">Replaced!</div>"),
    )
  })
  |> websocket.on_close(fn(subject: Subject(HandlerMessage)) {
    io.println("on_close: " <> string.inspect(subject))
  })
  |> mist.upgrade
}
