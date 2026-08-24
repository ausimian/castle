defmodule Castle.FileReasonTest do
  use ExUnit.Case, async: true

  alias Castle.FileReason

  test "includes each atom identity once across OTP file-error formats" do
    for reason <- [:eacces, :castle_not_a_posix_reason] do
      identity = Atom.to_string(reason)
      formatted = reason |> :file.format_error() |> to_string()
      rendered = FileReason.format(reason)

      assert rendered =~ formatted
      assert identity_occurrences(rendered, identity) == 1
      assert identity_occurrences(formatted, identity) in [0, 1]

      if identity_occurrences(formatted, identity) == 1 do
        assert rendered == formatted
      else
        assert rendered == "#{inspect(reason)} (#{formatted})"
      end
    end
  end

  test "inspects non-atom reasons" do
    assert FileReason.format({1, :erl_parse, :bad_term}) == "{1, :erl_parse, :bad_term}"
  end

  defp identity_occurrences(text, identity) do
    escaped = Regex.escape(identity)

    Regex.scan(Regex.compile!("(?<![[:alnum:]_])#{escaped}(?![[:alnum:]_])"), text)
    |> length()
  end
end
