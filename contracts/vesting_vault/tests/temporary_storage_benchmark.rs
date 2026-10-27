use soroban_sdk::{
    testutils::{Address as _, Ledger as _},
    Address, Env,
};
use vesting_vault::{VestingVault, VestingVaultClient};

#[test]
fn test_temporary_storage_claim_nonce_and_validation_cache() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(VestingVault, ());
    let client = VestingVaultClient::new(&env, &contract_id);

    let beneficiary = Address::generate(&env);

    assert_eq!(client.get_claim_nonce(&beneficiary), 0);
    assert!(!client.has_cached_claim_validation(&beneficiary, &1));

    client.claim(&beneficiary, &1, &500);
    assert_eq!(client.get_claim_nonce(&beneficiary), 1);
    assert!(client.has_cached_claim_validation(&beneficiary, &1));

    client.claim(&beneficiary, &1, &250);
    assert_eq!(client.get_claim_nonce(&beneficiary), 2);
}

#[test]
fn test_temporary_storage_paginated_claim_history_cursor() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(VestingVault, ());
    let client = VestingVaultClient::new(&env, &contract_id);

    let beneficiary = Address::generate(&env);
    let caller = Address::generate(&env);

    for i in 1..=5u32 {
        client.claim(&beneficiary, &i, &(i as i128 * 100));
    }

    let first_page = client.get_claims_paginated(&caller, &2);
    assert_eq!(first_page.len(), 2);
    assert_eq!(first_page.get(0).unwrap().vesting_id, 1);
    assert_eq!(first_page.get(1).unwrap().vesting_id, 2);

    let second_page = client.get_claims_paginated(&caller, &2);
    assert_eq!(second_page.len(), 2);
    assert_eq!(second_page.get(0).unwrap().vesting_id, 3);
    assert_eq!(second_page.get(1).unwrap().vesting_id, 4);

    let third_page = client.get_claims_paginated(&caller, &2);
    assert_eq!(third_page.len(), 1);
    assert_eq!(third_page.get(0).unwrap().vesting_id, 5);
}

#[test]
fn test_temporary_storage_authorized_payout_read_through_and_invalidation() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(VestingVault, ());
    let client = VestingVaultClient::new(&env, &contract_id);

    let beneficiary = Address::generate(&env);
    let payout = Address::generate(&env);

    client.set_authorized_payout_address(&beneficiary, &payout);
    assert!(client.get_pending_address_request(&beneficiary).is_some());

    // Advance past 48-hour timelock
    env.ledger().with_mut(|li| {
        li.timestamp += 172_801;
    });

    client.confirm_auth_payout_addr(&beneficiary);

    let cached_auth = client.get_authorized_payout_address(&beneficiary).unwrap();
    assert_eq!(cached_auth.authorized_address, payout);
    assert!(cached_auth.is_active);

    // Removal must invalidate both Instance and Temporary storage caches
    client.remove_authorized_payout_address(&beneficiary);
    assert!(client.get_authorized_payout_address(&beneficiary).is_none());
}

#[test]
fn test_benchmark_temporary_vs_instance_storage_resource_cost() {
    let env = Env::default();
    env.mock_all_auths();

    let contract_id = env.register(VestingVault, ());
    let user = Address::generate(&env);

    // Measure 50 Temporary storage reads/writes on a bloated contract instance vs 50 Instance storage reads/writes
    env.as_contract(&contract_id, || {
        // Populate 20 persistent-like entries in Instance storage to simulate real contract state
        for idx in 0..20u32 {
            env.storage().instance().set(&("BULK_STATE", idx), &(idx as i128 * 1000));
        }

        env.cost_estimate().budget().reset_default();
        for i in 0..50u64 {
            env.storage().temporary().set(&("BENCH_TEMP", user.clone()), &i);
            let val: u64 = env
                .storage()
                .temporary()
                .get(&("BENCH_TEMP", user.clone()))
                .unwrap_or(0);
            assert_eq!(val, i);
        }
        let temp_cpu = env.cost_estimate().budget().cpu_instruction_cost();
        let temp_mem = env.cost_estimate().budget().memory_bytes_cost();

        env.cost_estimate().budget().reset_default();
        for i in 0..50u64 {
            env.storage().instance().set(&("BENCH_INST", user.clone()), &i);
            let val: u64 = env
                .storage()
                .instance()
                .get(&("BENCH_INST", user.clone()))
                .unwrap_or(0);
            assert_eq!(val, i);
        }
        let inst_cpu = env.cost_estimate().budget().cpu_instruction_cost();
        let inst_mem = env.cost_estimate().budget().memory_bytes_cost();

        assert!(temp_cpu > 0 && inst_cpu > 0);
        assert!(temp_mem > 0 && inst_mem > 0);
    });
}
