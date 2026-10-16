defmodule Przma.Search.TextExtract do
  @moduledoc """
  Gets plain text out of a file so it can be indexed for search.

    * text-like files (txt, md, csv, json, html, code …) are read as they are
    * PDF uses the `pdftotext` command (Debian/Ubuntu package `poppler-utils`)
    * anything else (images, video, zip …) returns {:error, :unsupported_type}

      TextExtract.from_file("/tmp/report.pdf")
      TextExtract.from_binary(bytes, "notes.txt", "text/plain")
  """

  @text_ext ~w(.txt .md .markdown .csv .tsv .json .xml .html .htm .log .yaml .yml .ex .exs .py .js .ts .rs .sql)

  @spec from_file(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def from_file(path, mime \\ nil) do
    cond do
      pdf?(path, mime) -> pdftotext(path)
      text?(path, mime) -> with {:ok, bin} <- File.read(path), do: {:ok, scrub(bin)}
      true -> {:error, :unsupported_type}
    end
  end

  @doc "Same as from_file/2 for bytes already in memory (e.g. an upload)."
  @spec from_binary(binary(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def from_binary(bytes, filename, mime \\ nil) when is_binary(bytes) do
    cond do
      pdf?(filename, mime) ->
        tmp = Path.join(System.tmp_dir!(), "przma_extract_#{System.unique_integer([:positive])}.pdf")

        try do
          File.write!(tmp, bytes)
          pdftotext(tmp)
        after
          File.rm(tmp)
        end

      text?(filename, mime) ->
        {:ok, scrub(bytes)}

      true ->
        {:error, :unsupported_type}
    end
  end

  @spec supported?(String.t(), String.t() | nil) :: boolean()
  def supported?(filename, mime \\ nil), do: pdf?(filename, mime) or text?(filename, mime)

  defp pdf?(name, mime), do: mime == "application/pdf" or ext(name) == ".pdf"

  defp text?(name, mime),
    do: ext(name) in @text_ext or (is_binary(mime) and String.starts_with?(mime, "text/"))

  defp ext(name), do: name |> to_string() |> Path.extname() |> String.downcase()

  defp pdftotext(path) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error, :pdftotext_not_installed}

      exe ->
        case System.cmd(exe, ["-enc", "UTF-8", path, "-"], stderr_to_stdout: false) do
          {out, 0} -> {:ok, scrub(out)}
          {_out, code} -> {:error, {:pdftotext_failed, code}}
        end
    end
  end

  # Drop invalid UTF-8 bytes (works on every Elixir version).
  defp scrub(bin) do
    if String.valid?(bin) do
      bin
    else
      bin |> String.codepoints() |> Enum.filter(&String.valid?/1) |> Enum.join()
    end
  end
end
