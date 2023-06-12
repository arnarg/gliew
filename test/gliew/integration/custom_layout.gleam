import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request
import nakai/html
import nakai/html/attrs
import gliew

fn layout(content: html.Node(a)) {
  html.Html(
    [],
    [
      html.Head([gliew.script(), html.title("My custom layout!")]),
      html.Body(
        attrs: [],
        children: [html.div([attrs.class("container")], [content])],
      ),
    ],
  )
}

pub fn main() {
  let assert Ok(_) =
    gliew.Server(
      port: 8080,
      layout: layout,
      handler: fn(req) {
        case req.method, request.path_segments(req) {
          Get, ["hello"] ->
            html.div_text([], "Hello gleam!")
            |> gliew.view(200)
          _, _ ->
            html.div_text([], "Hello world!")
            |> gliew.view(200)
        }
      },
    )
    |> gliew.serve

  process.sleep_forever()
}
