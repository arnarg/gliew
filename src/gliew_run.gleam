import gleam/io
import gleam/int
import gleam/list
import gleam/http.{Get}
import gleam/http/request
import gleam/erlang/process
import nakai/html
import nakai/html/attrs
import gliew

pub type Person {
  Person(name: String, age: Int, profession: String)
}

pub type Counter {
  Counter(number: Int)
}

pub fn main() {
  let assert Ok(_) =
    gliew.serve(
      8080,
      fn(req) {
        io.debug(req)
        case req.method, request.path_segments(req) {
          Get, ["people"] -> people()
          Get, ["counter"] -> counter()
          _, _ -> home()
        }
      },
    )
  process.sleep_forever()
}

fn home() {
  use req <- gliew.Component

  io.debug(req)

  html.div_text([], "Hello gleam!")
}

fn counter() {
  use _ <- gliew.Component

  html.div_text([], "Counter is at 10")
}

fn people_mount() {
  Nil
}

fn people() {
  use _, _ <- gliew.LiveComponent(people_mount)

  let people = [
    Person("John", 30, "Plumber"),
    Person("Rosie", 45, "Secretary"),
    Person("Jane", 26, "Pilot"),
  ]

  html.div(
    [],
    [
      html.div_text([], "People:"),
      html.ul(
        [attrs.id("placeholder")],
        people
        |> list.map(fn(p) {
          html.li(
            [],
            [
              html.Text(p.name),
              html.ul(
                [],
                [
                  html.li(
                    [],
                    [
                      html.Text(
                        p.age
                        |> int.to_string,
                      ),
                    ],
                  ),
                  html.li([], [html.Text(p.profession)]),
                ],
              ),
            ],
          )
        }),
      ),
    ],
  )
}
