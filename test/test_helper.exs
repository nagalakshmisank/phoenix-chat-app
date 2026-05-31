ExUnit.start()

# Reset the HealthMonitor circuit breaker before every test.
# Without this, a test that triggers 5 errors trips the circuit and
# all subsequent tests in the same run fail with {:error, :circuit_open}.
defmodule PzDb.TestHelpers do
  use ExUnit.CaseTemplate

  setup do
    PRZMA.PzDb.HealthMonitor.reset()
    :ok
  end
end
