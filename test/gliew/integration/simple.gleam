import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request
import nakai/html
import gliew

pub fn main() {
  let assert Ok(_) =
    gliew.serve(
      8080,
      fn(req) {
        case req.method, request.path_segments(req) {
          Get, ["hello"] -> html.div_text([], "Hello gleam!")
          _, _ -> html.div_text([], "Hello world!")
        }
      },
    )

  process.sleep_forever()
}