import gleam/int
import gleam/option
import gleam/erlang/process.{Subject}
import gleam/http/request
import nakai/html
import gliew

pub fn main() {
  let assert Ok(_) =
    gliew.new(
      8080,
      fn(req) {
        case req.method, request.path_segments(req) {
          _, _ ->
            html.div([], [html.div_text([], "counter is at:"), counter()])
            |> gliew.view(200)
        }
      },
    )
    |> gliew.serve

  process.sleep_forever()
}

// This becomes the render function.
fn counter() {
  // Here we use the `use` syntax as kind of a decorator
  // to turn this function into a live mount.
  use assign <- gliew.live_mount(mount_counter, with: Nil)

  html.div_text(
    [],
    assign
    |> option.unwrap(0)
    |> int.to_string,
  )
}

// This is still the mount function.
fn mount_counter(_ctx) {
  let subject = process.new_subject()

  let _ = process.start(fn() { loop(subject, 0) }, True)

  subject
}

// Counter loop for demonstartion purposes.
fn loop(subject: Subject(Int), current: Int) {
  process.send(subject, current)
  process.sleep(1000)
  loop(subject, current + 1)
}
