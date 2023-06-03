import gleam/io
import gleam/string
import gleam/list
import gleam/result
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

pub type Component(a, b) {
  Component(render: fn(Request(Body)) -> html.Node(b))
  LiveComponent(
    mount: fn() -> Nil,
    render: fn(Request(Body), Option(a)) -> html.Node(b),
  )
}

pub fn component(render: fn(Request(Body)) -> html.Node(a)) {
  Component(render)
}

pub fn live_component(
  mount: fn() -> Nil,
  render: fn(Request(Body), Option(a)) -> html.Node(b),
) {
  LiveComponent(mount, render)
}

// Manager -----------------------------------------------

type LoopState {
  LoopState
}

type Message(a, b) {
  RenderComponent(
    from: Subject(html.Node(b)),
    request: Request(Body),
    component: Component(a, b),
  )
}

fn start_manager() {
  actor.start(LoopState, loop)
}

fn loop(message: Message(a, b), state: LoopState) -> actor.Next(LoopState) {
  case message {
    // Render a regular component
    RenderComponent(from, req, Component(render)) -> {
      process.send(from, render(req))

      actor.Continue(state)
    }
    // Render a live component
    RenderComponent(from, req, LiveComponent(_, render)) -> {
      process.send(
        from,
        render(req, None)
        |> process_live_component,
      )

      actor.Continue(state)
    }
  }
}

fn process_live_component(node: html.Node(a)) {
  case node {
    html.Element(tag, attrs, children) ->
      attrs
      |> list.prepend(attrs.Attr("hx-ext", "ws"))
      |> list.prepend(attrs.Attr(
        "ws-connect",
        "/connect?session=blabla&csrf=abcdefg",
      ))
      |> html.Element(tag, _, children)
    node -> node
  }
}

fn render_component(
  subject: Subject(Message(a, b)),
  request: Request(Body),
  component: Component(a, b),
) {
  process.call(subject, RenderComponent(_, request, component), 1000)
}

// Server ------------------------------------------------

pub fn serve(port: Int, handler: fn(Request(Body)) -> Component(a, b)) {
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
  handler: fn(Request(Body)) -> Component(a, b),
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

fn handle_ws_connect(_manager: Subject(Message(a, b)), request: Request(Body)) {
  fn(msg, _subject: Subject(HandlerMessage)) {
    io.debug(request)
    io.debug(msg)
    Ok(Nil)
  }
  |> websocket.with_handler
  |> websocket.on_init(fn(subject: Subject(HandlerMessage)) {
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
