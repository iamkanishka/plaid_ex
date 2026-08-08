defmodule PlaidEx.Config.TenantRegistryTest do
  use ExUnit.Case, async: false

  alias PlaidEx.Config
  alias PlaidEx.Config.TenantRegistry

  setup do
    tenant_id = "test_tenant_#{:rand.uniform(1_000_000)}"

    config =
      Config.new!(
        client_id: "tenant_client_id",
        secret: "tenant_secret",
        environment: :production,
        tenant_id: tenant_id
      )

    on_exit(fn -> TenantRegistry.deregister(tenant_id) end)
    {:ok, tenant_id: tenant_id, config: config}
  end

  describe "register/2 and get/1" do
    test "registers and retrieves a tenant config", %{tenant_id: tenant_id, config: config} do
      TenantRegistry.register(tenant_id, config)
      assert {:ok, retrieved} = TenantRegistry.get(tenant_id)
      assert retrieved.client_id == "tenant_client_id"
      assert retrieved.tenant_id == tenant_id
    end

    test "returns not_found for unregistered tenant" do
      assert :not_found = TenantRegistry.get("nonexistent_tenant_id")
    end

    test "get!/1 raises for unregistered tenant" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        TenantRegistry.get!("nonexistent_#{:rand.uniform(10_000)}")
      end
    end

    test "overwrites existing registration", %{tenant_id: tenant_id, config: config} do
      TenantRegistry.register(tenant_id, config)

      new_config = Config.rotate_secret(config, "new_secret_value")
      TenantRegistry.register(tenant_id, new_config)

      {:ok, retrieved} = TenantRegistry.get(tenant_id)
      assert retrieved.secret == "new_secret_value"
    end
  end

  describe "update_secret/2" do
    test "rotates secret without full re-registration", %{tenant_id: tenant_id, config: config} do
      TenantRegistry.register(tenant_id, config)
      assert :ok = TenantRegistry.update_secret(tenant_id, "rotated_secret_value")

      {:ok, updated} = TenantRegistry.get(tenant_id)
      assert updated.secret == "rotated_secret_value"
      assert updated.client_id == "tenant_client_id"
    end

    test "returns not_found for unregistered tenant" do
      result = TenantRegistry.update_secret("nonexistent_tenant", "new_secret")
      assert result == :not_found
    end
  end

  describe "deregister/1" do
    test "removes a registered tenant", %{tenant_id: tenant_id, config: config} do
      TenantRegistry.register(tenant_id, config)
      assert {:ok, _} = TenantRegistry.get(tenant_id)

      TenantRegistry.deregister(tenant_id)
      assert :not_found = TenantRegistry.get(tenant_id)
    end

    test "is idempotent for nonexistent tenant" do
      assert :ok = TenantRegistry.deregister("never_existed_tenant")
    end
  end

  describe "list_tenants/0" do
    test "lists all registered tenant IDs", %{tenant_id: tenant_id, config: config} do
      TenantRegistry.register(tenant_id, config)
      tenants = TenantRegistry.list_tenants()
      assert tenant_id in tenants
    end
  end

  describe "count/0" do
    test "returns the number of registered tenants", %{tenant_id: tenant_id, config: config} do
      initial_count = TenantRegistry.count()
      TenantRegistry.register(tenant_id, config)
      assert TenantRegistry.count() == initial_count + 1
    end
  end

  describe "concurrent access" do
    test "handles concurrent registrations safely" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            tid = "concurrent_tenant_#{i}_#{:rand.uniform(10_000)}"

            cfg =
              Config.new!(
                client_id: "c_#{i}",
                secret: "s_#{i}",
                tenant_id: tid
              )

            TenantRegistry.register(tid, cfg)
            {:ok, retrieved} = TenantRegistry.get(tid)
            assert retrieved.client_id == "c_#{i}"
            TenantRegistry.deregister(tid)
          end)
        end

      Task.await_many(tasks, 5_000)
    end
  end
end
