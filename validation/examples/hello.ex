defmodule Validation.Examples.Hello do
  def greet(name) do
    IO.puts("Hello, " <> name <> "!")
  end

  def sum(a, b) do
    a + b
  end

  def complex_match(opts \\ []) do
    opts
    |> Keyword.get(:format, :json)
    |> case do
      :json -> %{status: "ok", code: 200}
      :text -> "ok"
    end
  end
end
