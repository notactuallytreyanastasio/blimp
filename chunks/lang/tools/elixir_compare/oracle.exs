# elixir oracle.exs corpus.tsv > elixir.tsv
# The same row blimp_side.blimp writes, from Elixir's String module.
hex = fn s -> Base.encode16(s, case: :lower) end
# Elixir does not raise on most ill-formed input -- it counts a stray byte as
# a character -- but some of it does raise (String.length on a truncated
# U+FE0F), so every field is guarded and says RAISE when it did.
guard = fn f ->
  try do
    f.()
  rescue
    _ -> "RAISE"
  end
end
[path] = System.argv()
path
|> File.read!()
|> String.split("\n", trim: true)
|> Enum.each(fn line ->
  [label, h] = String.split(line, "\t")
  s = Base.decode16!(h, case: :lower)
  cps = String.codepoints(s)
  fields = [
    fn -> to_string(String.valid?(s)) end,
    fn -> hex.(String.replace_invalid(s)) end,
    fn -> to_string(length(cps)) end,
    fn -> to_string(String.length(s)) end,
    fn -> s |> String.graphemes() |> Enum.map(hex) |> Enum.join(",") end,
    fn -> hex.(String.upcase(s)) end,
    fn -> hex.(String.downcase(s)) end,
    fn -> hex.(String.slice(s, 0, 3)) end,
    fn -> hex.(cps |> Enum.slice(1, 2) |> Enum.join()) end,
    fn -> hex.(String.slice(s, 1, 2)) end
  ] |> Enum.map(guard)
  IO.puts(label <> "\t" <> Enum.join(fields, "|"))
end)
