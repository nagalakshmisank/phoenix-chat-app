defmodule PRZMA.Auth.Mailer do
  @moduledoc """
  Placeholder mail delivery for OTP / password-reset codes.

  This project has no mailer configured yet. Swap the bodies below for a
  real email send (e.g. Swoosh + your SMTP/SES provider) — everything else
  in the auth flow is already wired to call this module, so it's the only
  place you need to touch.
  """

  require Logger

  def deliver_otp(email, nickname, otp_plain) do
    Logger.info(
      "[Auth.Mailer] OTP for #{nickname} <#{email}>: #{otp_plain} (expires in 10 min)"
    )

    :ok
  end

  def deliver_reset(email, nickname, reset_token_plain, did) do
    Logger.info(
      "[Auth.Mailer] Password reset for #{nickname} <#{email}>: did=#{did} token=#{reset_token_plain} (expires in 15 min)"
    )

    :ok
  end
end