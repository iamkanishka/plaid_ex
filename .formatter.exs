[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [
    # NimbleOptions DSL
    field: :*,
    embeds_one: :*,
    embeds_many: :*
  ]
]
