# lib/przma/calendar/jobs/meeting_intelligence.ex
#
# Oban jobs for meeting intelligence pipeline:
# - Pre-brief delivery (10 min before meeting)
# - Transcription processing
# - Post-meeting reflection trigger

defmodule PRZMA.Calendar.Jobs.PreBriefDelivery do
  @moduledoc """
  Delivers pre-meeting brief to companion 10 minutes before event starts.
  Scheduled when a MEETING event is created or updated.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.PreBrief

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did, "event_id" => event_id}}) do
    case PreBrief.deliver_to_companion(did, event_id) do
      {:ok, _}      -> :ok
      {:error, msg} ->
        require Logger
        Logger.warning("Pre-brief delivery failed", event_id: event_id, error: msg)
        :ok  # Don't retry — pre-brief is best-effort
    end
  end

  @doc "Schedule pre-brief delivery 10 minutes before event start"
  def schedule(did, event_id, event_start_micros) do
    event_start  = DateTime.from_unix!(event_start_micros, :microsecond)
    trigger_at   = DateTime.add(event_start, -600, :second)  # 10 minutes before

    if DateTime.compare(trigger_at, DateTime.utc_now()) == :gt do
      %{did: did, event_id: event_id}
      |> new(scheduled_at: trigger_at)
      |> Oban.insert()
    else
      {:ok, :skipped}
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.TranscribeAudio do
  @moduledoc """
  Transcribes audio blobs using TFLite on-device.
  For Cloud SaaS mode: delegates to TF Serving endpoint.
  For Local/Own Domain: calls local TFLite NIF.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 3

  alias PRZMA.Calendar.{NIF, Intelligence.PostMeeting}

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "did"       => did,
    "event_id"  => event_id,
    "audio_cas" => audio_cas,
    "language"  => language,
  } = args}) do
    require Logger

    with {:ok, audio_data} <- NIF.cas_get(@base_path, did, audio_cas) do
      # Transcribe via TFLite (Phase 6: full model inference)
      # For Phase 4: produce a placeholder transcript structure
      transcript = transcribe(audio_data, language, did, event_id, audio_cas)
      PostMeeting.process_transcript(did, event_id, Jason.encode!(transcript))
    else
      {:error, msg} ->
        Logger.error("Transcription: audio not found", audio_cas: audio_cas, error: msg)
        {:discard, "Audio not found in CAS"}
    end
  end

  def enqueue(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> new()
    |> Oban.insert()
  end

  # Phase 4: structured transcript placeholder — real TFLite in Phase 6
  defp transcribe(audio_data, language, did, event_id, audio_cas) do
    now     = DateTime.utc_now()
    text_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    %{
      "id"             => "transcript-#{event_id}-#{text_id}",
      "event_id"       => event_id,
      "did"            => did,
      "space"          => "core",
      "audio_cas"      => audio_cas,
      "text_cas"       => "",    # Set after storing text
      "language"       => language,
      "status"         => "complete",
      "duration_secs"  => estimate_duration(byte_size(audio_data)),
      "word_count"     => 0,
      "speaker_count"  => 1,
      "turns"          => [],    # Phase 6: real speaker diarization
      "summary_cas"    => nil,
      "action_items"   => [],
      "is_shared"      => false,
      "shared_with"    => [],
      "created_at"     => DateTime.to_unix(now, :microsecond),
      "updated_at"     => DateTime.to_unix(now, :microsecond),
    }
  end

  defp estimate_duration(byte_size) do
    # Rough estimate: ~16KB/sec for typical audio
    div(byte_size, 16_000)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.PostMeetingTrigger do
  @moduledoc """
  Triggers the post-meeting reflection flow after an event ends.
  Scheduled when a MEETING or PRACTICE event is created.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.PostMeeting

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "did"      => did,
    "event_id" => event_id,
    "space"    => space,
  }}) do
    case PostMeeting.trigger(did, event_id, space: space) do
      {:ok, _}     -> :ok
      {:error, msg} ->
        require Logger
        Logger.warning("Post-meeting trigger failed",
          event_id: event_id, error: msg)
        :ok  # Best-effort
    end
  end

  @doc "Schedule post-meeting trigger 5 minutes after event ends"
  def schedule(did, event_id, event_end_micros, space \\ "core") do
    event_end  = DateTime.from_unix!(event_end_micros, :microsecond)
    trigger_at = DateTime.add(event_end, 300, :second)  # +5 min

    %{did: did, event_id: event_id, space: space}
    |> new(scheduled_at: trigger_at)
    |> Oban.insert()
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.SummaryBuilder do
  @moduledoc """
  Builds a meeting summary for optional circle sharing.
  Triggered after post-meeting reflection is submitted.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.PostMeeting

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "did"        => did,
    "event_id"   => event_id,
    "circle_did" => circle_did,
  }}) do
    with {:ok, summary} <- PostMeeting.build_summary(did, event_id) do
      if circle_did do
        PostMeeting.share_summary_to_circle_from_summary(did, circle_did, summary)
      end
      :ok
    else
      {:error, msg} ->
        require Logger
        Logger.warning("Summary build failed", event_id: event_id, error: msg)
        :ok
    end
  end

  def enqueue(did, event_id, circle_did \\ nil) do
    %{did: did, event_id: event_id, circle_did: circle_did}
    |> new(schedule_in: 60)
    |> Oban.insert()
  end
end
