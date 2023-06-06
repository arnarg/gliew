import gleam/int
import gleam/option.{Option}
import gleam/erlang/process.{Subject}
import gleam/http/request
import nakai/html
import gliew

pub fn main() {
  let assert Ok(_) =
    gliew.serve(
      8080,
      fn(req) {
        case req.method, request.path_segments(req) {
          _, _ ->
            html.div(
              [],
              [
                html.div_text([], "counter is at:"),
                gliew.mount(
                  mount: mount_counter,
                  with: Nil,
                  render: render_counter,
                ),
              ],
            )
        }
      },
    )

  process.sleep_forever()
}

// The render function is called with `None` on
// initial render but `Some(a)` every time there
// is a new value on the subject returned by the
// mount function.
fn render_counter(assign: Option(Int)) {
  html.div_text(
    [],
    assign
    |> option.unwrap(0)
    |> int.to_string,
  )
}

// This is the mount function.
fn mount_counter(_ctx) {
  let subject = process.new_subject()

  let _ = process.start(fn() { loop(subject, 0) }, True)

  subject
}

// Counter loop for demonstration purposes.
fn loop(subject: Subject(Int), current: Int) {
  process.send(subject, current)
  process.sleep(1000)
  loop(subject, current + 1)
}
