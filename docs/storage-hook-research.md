# Storage Hook Research

Status: research note. This is not a supported chest-locking feature yet.

This document captures current dedicated-server hook findings for storage-related gameplay. The useful discovery is that WindrosePlus can observe real server-side storage components, but the observed callbacks do not yet expose a safe authorization point for opening, depositing, taking, or transferring items.

## Current Findings

Dedicated-server UE4SS can register many R5 hooks successfully, including `/Script/R5.*` functions and at least one Blueprint path under `/Game/...GC_InteractNotification...:OnExecute`.

Some Blueprint/game functions are not hookable during initial mod load. In one storage test, `GC_InteractNotification:OnExecute` first failed with `UFunction::Func: 0x0`, then registered after a delayed rescan. For this reason, mods should prefer `WindrosePlus.API.registerHookWhenAvailable` when probing functions that may appear during or after world load.

Client UI, HUD, HFSM, and inventory view-model classes appear quiet on dedicated servers. Hooks such as `R5HUD:LaunchHFSM`, `R5HUD:TriggerHFSM`, `R5SC_Default:GetViewModel`, and `R5BaseInventoryVM:*` registered but did not fire during storage testing. Server-side mods should not expect the client inventory UI path to execute on the dedicated server.

The reliable server-side storage signals found so far are:

```text
/Script/R5.R5BuildingCenterStorageComponent:OnInventoryViewChanged
/Script/R5.R5ProximityStorageComponent:OnStorageComponentChanged
```

`R5BuildingCenterStorageComponent:GetOuter()` resolves to the actual `BP_BuildingBlock_BuildingCenterT01_C` actor, including world location. That makes it useful for mapping storage centers to world/building actors.

`R5ProximityStorageComponent` lives under `BP_R5PlayerState_C`, so proximity storage changes can be associated with a player-state object.

Observed storage callbacks had `arg_count = 0` and did not expose item, quantity, player, or action payloads. They should be treated as observer/update notifications, not as "can this player access this storage?" or "can this item move?" authorization hooks.

## Actionable Work

Use delayed registration for probes that may not be hookable at initial mod load:

```lua
local API = WindrosePlus.API

API.registerHookWhenAvailable(
    "/Script/R5.R5BuildingCenterStorageComponent:OnInventoryViewChanged",
    function(context)
        API.log("debug", "StorageProbe", "building center inventory view changed")
    end,
    { intervalMs = 5000, maxAttempts = 24, logSource = "StorageProbe" }
)
```

Use the existing debug/reflection commands to look for pre-access or pre-transfer functions around the live objects:

```text
wp.inspect R5BuildingCenterStorageComponent
wp.inspect R5ProximityStorageComponent
wp.fields R5BuildingCenterStorageComponent storage
wp.fields R5ProximityStorageComponent storage
wp.methods R5BuildingCenterStorageComponent access
wp.methods R5BuildingCenterStorageComponent transfer
wp.methods R5ProximityStorageComponent request
wp.peek R5ProximityStorageComponent <field_from_wp_fields>
```

Useful filter families to try with `wp.fields` and `wp.methods`:

```text
Can
Try
Request
Server
Open
Access
Use
Interact
Add
Remove
Transfer
Inventory
Storage
Owner
Player
Permission
Lock
```

If a candidate hook fires before storage open or item transfer, the next proof should log:

```text
function path
argument count
argument class/full name values
Context/GetOuter() chain
player-state or controller association
whether returning/overriding can deny the action
```

## Non-Goals Until a Gate Is Found

Do not ship chest locking based only on `OnInventoryViewChanged` or `OnStorageComponentChanged`. Those callbacks are useful telemetry, but they appear to fire after state/view changes and do not carry enough payload to enforce access safely.

Do not depend on HUD, HFSM, or client inventory view-model hooks for dedicated-server authority. Those paths may be client-only even when UE4SS can register the hook.

Do not mutate inventory data from observer callbacks unless the item API and save-state behavior are understood. WindrosePlus already has several inventory and stack-size safety lessons in related issues, and storage enforcement should stay conservative until an actual server authorization hook is identified.
