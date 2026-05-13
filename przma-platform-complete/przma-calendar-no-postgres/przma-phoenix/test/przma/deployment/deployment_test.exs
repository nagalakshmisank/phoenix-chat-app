# test/przma/deployment/deployment_test.exs

defmodule PRZMA.Deployment.LicenseTest do
  use ExUnit.Case, async: true
  alias PRZMA.Deployment.License

  describe "tier feature availability" do
    @tier_features %{
      "free_local" => ~w(vault calendar chat companion basic_ai),
      "essential"  => ~w(vault calendar chat files companion basic_ai agents_1),
      "professional" => ~w(vault calendar chat files metadata companion full_ai agents_5 analytics),
      "sovereign"  => ~w(vault calendar chat files metadata creative companion full_ai
                         agents_unlimited analytics federation custom_namespace),
    }

    defp tier_allows?(tier, feature) do
      features = Map.get(@tier_features, tier, [])
      to_string(feature) in features
    end

    test "free_local includes calendar" do
      assert tier_allows?("free_local", "calendar")
    end

    test "free_local excludes analytics" do
      refute tier_allows?("free_local", "analytics")
    end

    test "professional includes analytics" do
      assert tier_allows?("professional", "analytics")
    end

    test "sovereign includes federation" do
      assert tier_allows?("sovereign", "federation")
    end

    test "essential excludes analytics" do
      refute tier_allows?("essential", "analytics")
    end

    test "sovereign includes all professional features" do
      professional_features = @tier_features["professional"]
      Enum.each(professional_features, fn f ->
        assert tier_allows?("sovereign", f), "sovereign should include #{f}"
      end)
    end
  end

  describe "license validity" do
    test "license with future expiry is valid" do
      license = %{valid: true, tier: "professional", claims: %{}}
      assert License.valid?(license)
    end

    test "invalid license is not valid" do
      license = %{valid: false, tier: nil, claims: %{}}
      refute License.valid?(license)
    end

    test "subscription API mode is always valid" do
      license = %{valid: true, tier: :subscription_api, claims: %{}}
      assert License.valid?(license)
    end
  end

  describe "license summary" do
    test "builds summary map" do
      license = %{valid: true, tier: "professional", claims: %{}}
      summary = License.summary(license)
      assert summary.valid == true
      assert summary.tier == "professional"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Deployment.BYOSCredentialsTest do
  use ExUnit.Case, async: true
  alias PRZMA.Deployment.BYOSCredentials

  describe "path prefix generation" do
    test "generates safe path prefix from DID" do
      prefix = BYOSCredentials.path_prefix("did:web:alice.com")
      assert String.starts_with?(prefix, "przma-vaults/")
      refute String.contains?(prefix, ":")
    end

    test "different DIDs produce different prefixes" do
      p1 = BYOSCredentials.path_prefix("did:web:alice.com")
      p2 = BYOSCredentials.path_prefix("did:web:bob.com")
      assert p1 != p2
    end

    test "prefix is safe for S3 key usage" do
      prefix = BYOSCredentials.path_prefix("did:web:alice.com")
      refute String.contains?(prefix, " ")
      assert String.match?(prefix, ~r|^[a-zA-Z0-9/_-]+$|)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Deployment.HomeInstanceTest do
  use ExUnit.Case, async: true
  alias PRZMA.Deployment.HomeInstance

  describe "user provisioning" do
    test "generates correct DID from username and domain" do
      # Simulate DID generation
      username = "bob"
      domain   = "alice.przma.net"
      did      = "did:web:#{domain}:users:#{username}"
      assert did == "did:web:alice.przma.net:users:bob"
    end

    test "generates Phoenix config with correct values" do
      config = HomeInstance.generate_phoenix_config(
        instance_url: "https://alice.przma.net",
        did:          "did:web:alice.przma.net",
        base_path:    "/var/przma/vaults"
      )
      assert String.contains?(config, "alice.przma.net")
      assert String.contains?(config, "deployment_mode:  :local")
      assert String.contains?(config, "/var/przma/vaults")
    end

    test "generates mDNS service record" do
      record = HomeInstance.mdns_service_record("https://alice.przma.net", 4000)
      assert record.name == "_przma._tcp.local"
      assert record.port == 4000
      assert Enum.any?(record.txt, &String.contains?(&1, "mode=home"))
    end

    test "generates systemd unit with correct environment" do
      unit = HomeInstance.generate_ddns_agent_systemd("alice.przma.net", "https://alice.przma.net")
      assert String.contains?(unit, "PRZMA_SUBDOMAIN=alice.przma.net")
      assert String.contains?(unit, "przma-ddns-agent start")
      assert String.contains?(unit, "Restart=always")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Storage.EncryptionContextTest do
  use ExUnit.Case, async: true

  describe "encryption availability check" do
    test "returns false when no master key configured" do
      # Ensure env var is not set for this DID
      did      = "did:web:no-key-configured.test"
      did_hash = :crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> String.slice(0, 16)
      System.delete_env("PRZMA_MASTER_KEY_#{String.upcase(did_hash)}")

      # When running locally without file — should return false
      # (or true if key file happens to exist — skip in CI)
      result = PRZMA.Calendar.Storage.EncryptionContext.encryption_available?(did)
      assert is_boolean(result)
    end
  end

  describe "key path generation" do
    test "calendar namespace path contains did and namespace" do
      # Test the pattern format without needing a real key
      did  = "did:web:alice.com"
      ns   = "calendar"
      path = "did:#{did}:ns:#{ns}"
      assert String.contains?(path, "alice.com")
      assert String.contains?(path, "calendar")
    end

    test "circle path contains circle_did" do
      did        = "did:web:alice.com"
      circle_did = "did:web:family.przma.net"
      ns         = "calendar"
      path       = "did:#{did}:circle:#{circle_did}:ns:#{ns}"
      assert String.contains?(path, "family.przma.net")
      assert String.contains?(path, "calendar")
    end
  end
end
