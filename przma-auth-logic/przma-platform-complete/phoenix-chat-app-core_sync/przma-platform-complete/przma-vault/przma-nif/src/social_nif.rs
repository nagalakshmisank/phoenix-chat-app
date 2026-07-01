// przma-nif/src/social_nif.rs
//
// Social graph NIFs — circle memberships and AP followers.
// Replaces all PRZMA.Repo calls in the Elixir layer.

use przma_calendar::social::{
    CircleMembership, Follower, MembershipStore, FollowerStore,
};
use rustler::{Encoder, Env, Term};
use crate::{atoms, err_atom, ok_json, runtime};

/// social_insert_membership(base_path, membership_json) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_insert_membership<'a>(
    env:             Env<'a>,
    base_path:       String,
    membership_json: String,
) -> Term<'a> {
    let m: CircleMembership = match serde_json::from_str(&membership_json) {
        Ok(m)  => m,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match MembershipStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.insert(&m).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// social_get_role(base_path, did, circle_did) -> {:ok, role_json} | {:error, "not_found"}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_get_role<'a>(
    env:        Env<'a>,
    base_path:  String,
    did:        String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match MembershipStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.get_role(&did, &circle_did).await {
            Ok(Some(role)) => ok_json(env, &role),
            Ok(None)       => (atoms::error(), "not_found").encode(env),
            Err(e)         => err_atom(env, &e.to_string()),
        }
    })
}

/// social_deactivate_membership(base_path, did, circle_did) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_deactivate_membership<'a>(
    env:        Env<'a>,
    base_path:  String,
    did:        String,
    circle_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match MembershipStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.deactivate(&did, &circle_did).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// social_update_role(base_path, did, circle_did, new_role) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_update_role<'a>(
    env:        Env<'a>,
    base_path:  String,
    did:        String,
    circle_did: String,
    new_role:   String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match MembershipStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.update_role(&did, &circle_did, &new_role).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// social_list_circles_for(base_path, did) -> {:ok, memberships_json}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_list_circles_for<'a>(
    env:       Env<'a>,
    base_path: String,
    did:       String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match MembershipStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.list_circles_for(&did).await {
            Ok(memberships) => ok_json(env, &memberships),
            Err(e)          => err_atom(env, &e.to_string()),
        }
    })
}

/// social_insert_follower(base_path, follower_json) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_insert_follower<'a>(
    env:           Env<'a>,
    base_path:     String,
    follower_json: String,
) -> Term<'a> {
    let f: Follower = match serde_json::from_str(&follower_json) {
        Ok(f)  => f,
        Err(e) => return err_atom(env, &e.to_string()),
    };
    runtime().block_on(async {
        let store = match FollowerStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.insert(&f).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}

/// social_list_followers(base_path, owner_did) -> {:ok, followers_json}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_list_followers<'a>(
    env:       Env<'a>,
    base_path: String,
    owner_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match FollowerStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.list(&owner_did).await {
            Ok(followers) => ok_json(env, &followers),
            Err(e)        => err_atom(env, &e.to_string()),
        }
    })
}

/// social_remove_follower(base_path, owner_did, follower_did) -> :ok | {:error, reason}
#[rustler::nif(schedule = "DirtyIo")]
pub fn social_remove_follower<'a>(
    env:          Env<'a>,
    base_path:    String,
    owner_did:    String,
    follower_did: String,
) -> Term<'a> {
    runtime().block_on(async {
        let store = match FollowerStore::new(&base_path).await {
            Ok(s)  => s,
            Err(e) => return err_atom(env, &e.to_string()),
        };
        match store.remove(&owner_did, &follower_did).await {
            Ok(())  => atoms::ok().encode(env),
            Err(e)  => err_atom(env, &e.to_string()),
        }
    })
}
