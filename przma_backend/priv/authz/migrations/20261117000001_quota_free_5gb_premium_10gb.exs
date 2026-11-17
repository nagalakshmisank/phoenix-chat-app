defmodule Przma.Authz.Repo.Migrations.QuotaFree5gbPremium10gb do
  @moduledoc """
  One bucket per user. Free = 5 GB, premium = 10 GB (same bucket, bigger
  quota). The seed used ON CONFLICT DO NOTHING, so existing rows are
  updated here. Business is left as it was.
  """
  use Ecto.Migration

  def up do
    execute "UPDATE przma_authz.plans SET storage_quota_bytes = 5368709120  WHERE code = 'free'"
    execute "UPDATE przma_authz.plans SET storage_quota_bytes = 10737418240 WHERE code = 'premium'"

    # users already on premium get the new quota too
    execute """
    UPDATE przma_authz.storage_usage su
       SET quota_bytes = p.storage_quota_bytes, updated_at = now()
      FROM przma_authz.accounts a
      JOIN przma_authz.plans p ON p.code = a.plan_code
     WHERE su.did = a.did AND a.plan_code IN ('free', 'premium')
    """
  end

  def down, do: :ok
end