# Windrose+ Configuration Reference

Windrose+ uses `windrose_plus.json` for everyday settings and optional `.ini` files for advanced game-balance overrides. Start with `windrose_plus.json` unless you specifically need one of the advanced tuning tables below.

| File | Purpose |
|------|---------|
| `windrose_plus.json` | Basic settings: multipliers, RCON, admins, performance options |
| `windrose_plus.ini` | Advanced settings: player stats, talents, combat |
| `windrose_plus.weapons.ini` | Per-weapon damage, crit, posture, special effects |
| `windrose_plus.food.ini` | Food buffs, consumables, alchemy items |
| `windrose_plus.gear.ini` | Armor sets, set bonuses, jewelry |
| `windrose_plus.entities.ini` | Land and naval entity base stats |

---

## windrose_plus.json (Basic Config)

This file is created automatically on first start. Edit it for common server-owner changes.

### server

Dashboard listener settings.

| Key | Default | Description |
|-----|---------|-------------|
| `http_port` | `8780` | Dashboard/API HTTP port. You can also pass `-Port` to `start_dashboard.bat`. |
| `bind_ip` | `""` | Optional IP address to bind the dashboard to on multi-IP hosts. Empty means all interfaces when elevated, with localhost fallback. You can also pass `-BindIp` to `start_dashboard.bat`. |

Example:

```json
{
    "server": {
        "http_port": 8780,
        "bind_ip": "192.0.2.10"
    }
}
```

### performance

Idle CPU limiting is optional for self-hosted servers. It lowers CPU only when nobody is connected, then restores full CPU when activity is detected.

| Key | Default | Description |
|-----|---------|-------------|
| `idle_cpu_limiter_enabled` | `false` | Set to `true` to opt in. After changing this, rerun `install.ps1` and restart the server. |
| `idle_cpu_limit_percent` | `2.0` | Idle CPU cap as a percent of total CPU. Leave at `2.0` unless players report slow joins or loading timeouts. |

Example:

```json
{
    "performance": {
        "idle_cpu_limiter_enabled": true,
        "idle_cpu_limit_percent": 2.0
    }
}
```

---

## windrose_plus.ini (Main Config)

### [Server]

Server network and admin settings.

| Key | Default | Description |
|-----|---------|-------------|
| `http_port` | `8780` | WindrosePlus HTTP API port |
| `game_port` | *(blank)* | Game port (auto-detected if blank) |
| `server_dir` | *(blank)* | Path to server directory (auto-detected if blank) |
| `rcon_enabled` | `false` | Enable RCON remote console |
| `rcon_password` | *(blank)* | RCON password (leave blank to disable) |
| `query_enabled` | `true` | Enable server query responses |
| `query_interval_ms` | `5000` | Query polling interval in milliseconds |
| `admin_steam_ids` | *(blank)* | Admin Steam IDs (comma-separated) |

### [Multipliers]

Global server multipliers. `1.0` = default, `2.0` = double, `0.5` = half.

| Key | Default | Description |
|-----|---------|-------------|
| `loot` | `1` | Loot drop quantity from chests / containers / enemies. Equipment drops are excluded so gear can't be duplicated. Use `harvest_yield` for resource nodes. |
| `xp` | `1` | Experience gain. Faster leveling means more talent/stat point payouts; that's the natural game progression, not a separate multiplier. |
| `stack_size` | `1` | Item stack sizes. Items that ship as unstackable (gear, jewelry, lore notes) stay unstackable. |
| `craft_cost` | `1` | Crafting material cost (0.5 = half cost) |
| `crop_speed` | `1` | Crop growth speed (2.0 = twice as fast) |
| `cooking_speed` | `1` | Cooking / fermentation / smelting speed (2.0 = twice as fast) |
| `harvest_yield` | `1` | Resource node yield (berries, ore, wood, herbs, etc.). Scales `Amount.Min`/`Max` per node; minimum stays at `1` after rounding. |
| `weight` | `1` | Per-item weight (`2.0` makes items heavier, `0.5` lighter) |
| `inventory_size` | `1` | Player / chest / ship / building inventory slot counts |
| `points_per_level` | `1` | Talent / stat / skill points granted per level-up |

Save-safety notes:

- `inventory_size`, `stack_size`, `weight`, and similar inventory-affecting changes can become part of player save state after login/save. Back up saves before enabling them.
- Do not combine Windrose+ PAK overrides with other PAK mods that edit the same assets unless you have tested the exact combination and can restore from backup.
- To fully disable Windrose+ during recovery testing, stop the server, rename `R5\Binaries\Win64\dwmapi.dll`, delete or move `R5\Content\Paks\WindrosePlus_Multipliers_P.pak` and `R5\Content\Paks\WindrosePlus_CurveTables_P.pak`, then delete `R5\Content\Paks\.windroseplus_build.hash`.

### [PlayerStats]

Player base attributes. Values are absolute, not multipliers. CurveTable: `CT_CharactersAttributes`.

| Key | Default | Raw Name | Description |
|-----|---------|----------|-------------|
| `MaxHealth` | `320` | Hero_MaxHealth | Maximum health points |
| `MaxStamina` | `150` | Hero_MaxStamina | Maximum stamina |
| `StaminaRegRate` | `40` | Hero_StaminaRegRate | Stamina regeneration rate |
| `MaxPosture` | `40` | Hero_MaxPosture | Maximum posture (stagger bar) |
| `PostureRegRate` | `20` | Hero_PostureRegRate | Posture regeneration rate |
| `Armor` | `0` | Hero_Armor | Base armor value |
| `DefencePwr` | `90` | Hero_DefencePwr | Base defence power |
| `StaggerDefence` | `3` | Hero_StaggerDefence | Stagger defence |
| `MaxWeight` | `99999` | Hero_MaxWeight | Maximum carry weight |
| `PassHPReg` | `0` | Hero_PassHPReg | Passive health regen per tick |
| `CorruptionStatusBuildupResistMax` | `0.65` | Hero_CorruptionStatusBuildupResistMax | Max corruption resistance (0-1) |

### [Talents]

Talent tree values for all 4 specializations. DmgMod values are percentages as decimals (0.03 = 3%). CurveTable: `CT_TalentData`.

#### Crusher (Heavy Melee)

| Key | Default | Description |
|-----|---------|-------------|
| `Crusher_Berserk_DmgMod` | `0.03` | Berserk damage modifier per stack |
| `Crusher_Berserk_HPRatioForOneStack` | `0.15` | HP ratio threshold for one berserk stack |
| `Crusher_Berserk_LowerHPRatioLimit` | `0` | Lower HP ratio limit for berserk |
| `Crusher_Berserk_ModForOneStack` | `1` | Modifier value for one berserk stack |
| `Crusher_Berserk_UpperHPRatioLimit` | `1` | Upper HP ratio limit for berserk |
| `Crusher_ChargedAttackDamage_DmgMod` | `0.04` | Charged attack damage bonus |
| `Crusher_CrudeDamage_DmgMod` | `0.03` | Crude damage bonus |
| `Crusher_DamageForDeathNearby_DmgMod` | `0.06` | Damage bonus when enemies die nearby |
| `Crusher_DamageForDeathNearby_Duration` | `60` | Duration of death-nearby buff (seconds) |
| `Crusher_DamageForDeathNearby_RadiusInMeters_UI` | `8` | Radius for death detection (meters) |
| `Crusher_DamageForMultipleTargets_Duration` | `30` | Multi-target buff duration (seconds) |
| `Crusher_DamageForMultipleTargets_MaxStack_UI` | `3` | Max stacks for multi-target buff |
| `Crusher_DamageForMultipleTargets_ModPerStack` | `0.05` | Damage bonus per stack |
| `Crusher_DamageForMultipleTargets_RequiredTargets_UI` | `2` | Targets needed to trigger |
| `Crusher_DamageResistInAttack_DmgResist` | `0.1` | Damage resistance while attacking |
| `Crusher_DamageResistWithTwoHandedWpn` | `0.05` | Damage resistance with two-handed weapons |
| `Crusher_HeavyAttackPostureDmgBuff_PostDmgMod` | `0.1` | Heavy attack posture damage bonus |
| `Crusher_InterruptResistInAttack_DmgResist` | `0.1` | Interrupt resistance while attacking |
| `Crusher_TemporalHPHealBuff_DmgDealConvMod` | `0.4` | Damage-to-temp-HP conversion rate |
| `Crusher_TwoHandedDamage_DmgMod` | `0.05` | Two-handed weapon damage bonus |
| `Crusher_TwoHandedMeleeCritChance` | `0.04` | Two-handed melee crit chance |
| `Crusher_TwoHandedStaminaReduced_StamMod` | `-0.1` | Two-handed stamina cost reduction |

#### Fencer (Light Melee)

| Key | Default | Description |
|-----|---------|-------------|
| `Fencer_ConsecutiveMeleeHitsBonus_DamageMod` | `0.03` | Damage bonus per consecutive hit |
| `Fencer_ConsecutiveMeleeHitsBonus_Duration` | `10` | Consecutive hits buff duration (seconds) |
| `Fencer_ConsecutiveMeleeHitsBonus_MaxStack_UI` | `5` | Max stacks for consecutive hits |
| `Fencer_CritChanceForPerfectBlock_CritChanceAdd` | `0.05` | Crit chance bonus after perfect block |
| `Fencer_CritChanceForPerfectBlock_Duration` | `12` | Perfect block crit buff duration (seconds) |
| `Fencer_DamageForBlock_DmgMod` | `0.01` | Damage bonus per block |
| `Fencer_DamageForSoloEnemy_DmgMod` | `0.06` | Damage bonus vs single enemy |
| `Fencer_HealForKill_Duration` | `20` | Heal-on-kill buff duration (seconds) |
| `Fencer_HealForKill_HealPerTick` | `10` | HP healed per tick on kill |
| `Fencer_HealForKill_TickPeriod` | `1` | Seconds between heal ticks |
| `Fencer_LessStaminaForDash_StamMod` | `-0.15` | Dash stamina cost reduction |
| `Fencer_OneHandedDamage_DmgMod` | `0.04` | One-handed weapon damage bonus |
| `Fencer_OneHandedMeleeCritChance` | `0.03` | One-handed melee crit chance |
| `Fencer_ParryWindowBonus_AddTime` | `0.02` | Extra parry window time (seconds) |
| `Fencer_PassiveReloadBoostForPerfectBlock_TimeRatio` | `0.15` | Passive reload boost after perfect block |
| `Fencer_PassiveReloadBoostForPerfectDodge_TimeRatio` | `0.25` | Passive reload boost after perfect dodge |
| `Fencer_RestoreForKill_PostureRestored` | `20` | Posture restored on kill |
| `Fencer_RestoreForKill_StaminaRestored` | `0.2` | Stamina restored on kill (ratio) |

#### Marksman (Ranged)

| Key | Default | Description |
|-----|---------|-------------|
| `Marksman_ActiveReloadSpeedBonus_PlayRateMod` | `0.1` | Active reload speed bonus |
| `Marksman_ConsecutiveRangeHitsBonus_DamageMod` | `0.05` | Damage bonus per consecutive ranged hit |
| `Marksman_ConsecutiveRangeHitsBonus_Duration` | `25` | Consecutive ranged hits buff duration (seconds) |
| `Marksman_ConsecutiveRangeHitsBonus_MaxStack_UI` | `4` | Max stacks for consecutive ranged hits |
| `Marksman_DamageForAimingState_DmgModPerStack` | `0.03` | Damage bonus per aiming stack |
| `Marksman_DamageForAimingState_MaxStack_UI` | `4` | Max stacks while aiming |
| `Marksman_DamageForAimingState_TickTime_UI` | `2` | Seconds per aiming stack |
| `Marksman_DamageForDistance_DmgModPer10m` | `0.01` | Damage bonus per 10m distance |
| `Marksman_DamageForPointBlank_DmgMod` | `0.04` | Point-blank damage bonus |
| `Marksman_Overpenetration_DmgDecreasePerHit` | `0.5` | Damage falloff per target penetrated |
| `Marksman_PassiveReloadBonus_TimeMod` | `-0.05` | Passive reload time reduction |
| `Marksman_PierceDamage` | `0.03` | Pierce damage bonus |
| `Marksman_RangeArmorPenBonus_AddPen` | `8` | Armor penetration bonus |
| `Marksman_RangeCritDamageBonus_CritDmgMod` | `0.05` | Ranged crit damage bonus |
| `Marksman_RangeDamageBonus_DmgMod` | `0.05` | Ranged damage bonus |
| `Marksman_RangeDamageToOutOfPosture_DmgMod` | `0.03` | Damage bonus vs posture-broken targets |
| `Marksman_ReloadForKill_ChanceTo` | `0.15` | Chance to instant-reload on kill |
| `Marksman_ScatterReductionBonus_ScatMod` | `-0.08` | Scatter/spread reduction |
| `Marksman_TempHPRestoreBonusForRange_ConvRateMod` | `0.1` | Ranged damage to temp HP conversion |

#### ToughGuy (Tank/Survival)

| Key | Default | Description |
|-----|---------|-------------|
| `ToughGuy_DamageResistForHP_HPRatioForOneStack` | `0.15` | HP ratio per damage resist stack |
| `ToughGuy_DamageResistForHP_LowerHPRatioLimit` | `0` | Lower HP limit for resist scaling |
| `ToughGuy_DamageResistForHP_Mod` | `0.04` | Damage resist modifier per stack |
| `ToughGuy_DamageResistForHP_ModForOneStack` | `1` | Modifier for one stack |
| `ToughGuy_DamageResistForHP_UpperHPRatioLimit` | `1` | Upper HP limit for resist scaling |
| `ToughGuy_HealEffectivness_HealMod` | `0.1` | Healing effectiveness bonus |
| `Toughguy_BlockPostureConsumptionBonus_Mod` | `-0.15` | Block posture cost reduction |
| `Toughguy_DamageForManyEnemies_Mod` | `0.04` | Damage bonus vs multiple enemies |
| `Toughguy_ElementalDamageResist_Mod` | `0.02` | Elemental damage resistance |
| `Toughguy_ExtraHP_Add` | `120` | Flat bonus HP |
| `Toughguy_GlobalDamageResist_Mod` | `0.06` | Global damage resistance |
| `Toughguy_PhysicalMeleeDamageResist_Mod` | `0.02` | Physical melee damage resistance |
| `Toughguy_PhysicalRangeDamageResist_Mod` | `0.04` | Physical ranged damage resistance |
| `Toughguy_ResistForManyEnemies_Mod` | `0.08` | Resistance bonus vs multiple enemies |
| `Toughguy_SaveOnLowHP_Cooldown` | `960` | Low HP save cooldown (seconds) |
| `Toughguy_SaveOnLowHP_HpPercentRestored` | `0.3` | HP restored on low-HP save (30%) |
| `Toughguy_SaveOnLowHP_HpPercentTrigger` | `0.1` | HP threshold to trigger save (10%) |
| `Toughguy_StaminaBonus_Add` | `20` | Flat bonus stamina |
| `Toughguy_TempHPForDamageRecivedBonus_Mod` | `0.25` | Damage-taken to temp HP conversion |

Note: The game uses mixed casing (`ToughGuy_` vs `Toughguy_`). Both prefixes are in the same `[Talents]` section. Use the exact casing shown.

### [CoopScaling]

Difficulty scaling per additional player. `0.0` = no scaling. CurveTable: `CT_Mob_StatCorrection_CoopBased`.

| Key | Default | Description |
|-----|---------|-------------|
| `HealthModifier` | `0` | Enemy health bonus per extra player |
| `ShipHealthModifier` | `0` | Ship enemy health bonus per extra player |

### [RestEffects]

Bonuses while resting at campfire or bed. CurveTable: `CT_RestGameplayEffectCurves`.

| Key | Default | Description |
|-----|---------|-------------|
| `PassiveHealthRegen` | `3` | HP regen per tick while resting |
| `StaminaRegen` | `1` | Stamina regen multiplier while resting |
| `StaminaRegenFlat` | `80` | Flat stamina regen while resting |
| `ExtraStamina` | `0` | Bonus stamina while resting |

### [Swimming]

Swimming damage and stamina drain. CurveTable: `CT_OtherGEValues`.

| Key | Default | Description |
|-----|---------|-------------|
| `Swimming_HealthDamage_Amount_Flat` | `12` | Flat HP loss per tick |
| `Swimming_HealthDamage_Amount_Percent` | `0.02` | % of max HP lost per tick |
| `Swimming_HealthDamage_TickPeriod` | `1` | Seconds between HP drain ticks |
| `Swimming_StaminaConsumption_Amount` | `-1.5` | Stamina drain per tick |
| `Swimming_StaminaConsumption_TickPeriod` | `0.2` | Seconds between stamina drain ticks |

### [SharedCombatEffects]

Bleed and weakness effects shared across all weapons. CurveTable: `CT_OtherGEValues`.

| Key | Default | Description |
|-----|---------|-------------|
| `Weapon_Shared_Bleed_DPS` | `25` | Bleed damage per tick |
| `Weapon_Shared_Bleed_Duration` | `14` | Bleed duration (seconds) |
| `Weapon_Shared_Bleed_Period` | `1.5` | Seconds between bleed ticks |
| `Weapon_Shared_Bleed_TotalDamage_UI` | `350` | Total bleed damage (UI display) |
| `Weapon_Shared_Weakness_Duration` | `14` | Weakness duration (seconds) |
| `Weapon_Shared_Weakness_Value` | `0.15` | Weakness effect strength |

### [Hearth]

Hearth/campfire proximity effects. CurveTable: `CT_OtherGEValues`.

| Key | Default | Description |
|-----|---------|-------------|
| `Hearth_PassiveHealthRegen` | `20` | HP regen per tick near hearth |
| `Hero_PassiveHealthRegen_TickPeriod` | `0.5` | Seconds between HP regen ticks |

---

## windrose_plus.weapons.ini

Type-specific `.ini` files can be used without creating a root `windrose_plus.ini`. The PAK builder reads `windrose_plus.weapons.ini`, `windrose_plus.food.ini`, `windrose_plus.gear.ini`, and `windrose_plus.entities.ini` independently and includes them in the rebuild hash.

Per-weapon damage, crit, posture, and special effect values. CurveTable: `CT_Weapon_GE_Values`.

**25 sections, 297 keys total.**

### Sections

`Ammo`, `Axe`, `Blunderbuss`, `Club`, `Greatsword`, `Halberd`, `MainHand_Axe1h`, `MainHand_Club`, `MainHand_Fistis`, `MainHand_Pickaxe`, `MainHand_Rapier`, `MainHand_Saber`, `Musket`, `OffHand_Pistol`, `Pickaxe`, `Pistol`, `Rapier`, `Saber`, `Shovel`, `Torch`, `TwoHand_Axe2h`, `TwoHand_Halberd`, `TwoHand_Machete`, `TwoHand_Musket`, `TwoHand_Shovel`

### Key naming pattern

`{WeaponType}_{Variant}_{Stat}` where variant includes tier (`T00`-`T03`) or named variants (e.g., `Dragonbreath`, `Reliable`, `Blank`).

### Common stats per weapon

- `BaseDamage` -- base damage value (typical range: 100-400)
- `MaxPostureAdd` -- posture damage bonus
- `PostureDmgMod` -- posture damage modifier
- `CritDmgModAdd` -- critical damage modifier
- `ArmorPenAdd` -- armor penetration
- `AttackPwrMod` -- attack power modifier
- UI effect values (`UI_Effect1`, `UI_Effect2`) for special procs

### Example entries

```ini
[Axe]
Axe_T00_BaseDamage = 240
Axe_T01_BaseDamage = 255
Axe_T02_BaseDamage = 255
Axe_T03_BaseDamage = 255

[Blunderbuss]
Blunderbuss_Blank_BaseDamage = 150
Blunderbuss_Dragonbreath_BaseDamage = 160
Blunderbuss_Dragonbreath_FireBlastProcChance = 0.6
Blunderbuss_Reliable_BaseDamage = 180
```

---

## windrose_plus.food.ini

Food, consumable, and alchemy stats. Durations in seconds, attribute buffs are absolute values.

**16 sections, 522 keys total.**

### Sections

**Cooked Food** (CurveTable: `CT_Food_GE_Values`): `Food_Dough`, `Food_Drink`, `Food_Raw`, `Food_RumBottle`, `Food_Second`, `Food_Skewer`, `Food_Soup`, `Food_Sweet`

**Consumables** (CurveTable: `CT_Consumable_GE_Values`): `Consumables_FoodTier1`, `Consumables_FoodTier2`, `Consumables_FoodTier3`, `Consumables_Other`

**Alchemy** (CurveTable: `CT_Alchemy_GE_Values`): `Alchemy_Bandages`, `Alchemy_Elixirs`, `Alchemy_Oils`, `Alchemy_Potions`

### Key naming pattern

`{Category}_{ItemName}_{Tier}_{Stat}` -- e.g., `Food_Dough_BurritoBeans_T03_Duration`.

### Common stats per food item

- `Duration` -- buff duration in seconds (typical: 900-1800)
- `MaxHealth` -- max health buff (typical: 80-160)
- `MaxStamina` -- max stamina buff
- `StaminaRegenRate` -- stamina regen buff
- `Fortitude` -- fortitude attribute buff (typical: 5-20)
- `Mastery` -- mastery attribute buff (typical: 5-20)

### Example entries

```ini
[Food_Dough]
Food_Dough_BurritoBeans_T03_Duration = 1800
Food_Dough_BurritoBeans_T03_Fortitude = 20
Food_Dough_BurritoBeans_T03_MaxHealth = 160
Food_Dough_BurritoMeat_T02_Duration = 1800
Food_Dough_BurritoMeat_T02_Mastery = 10
Food_Dough_CornCasabe_T02_Duration = 900
```

---

## windrose_plus.gear.ini

Armor sets, set bonuses, and jewelry effects. CurveTable: `CT_Armor_GE_Values`.

**18 sections, 113 keys total.**

### Sections

**Armor Sets**: `Armor_Bandit`, `Armor_Brigant`, `Armor_Conquistador`, `Armor_ConquistadorLegacy`, `Armor_Flibustier`, `Armor_Mercenary`, `Armor_Pikeman`, `Armor_Starter`, `Armor_Vanilla`

**Set Bonuses**: `Bandit_SetBonus`, `Conquistador_SetBonus`, `Flibustier_SetBonus`, `Mercenary_SetBonus`, `Pikeman_SetBonus`, `Vanilla_SetBonus`

**Jewelry**: `Jewelry`, `Necklaces`, `Rings`

### Key naming pattern

Armor: `{Set}_{Slot}_Armor` where slot is `Feet`, `Hands`, `Head`, `Legs`, `Torso`.

### Example entries

```ini
[Armor_Bandit]
Armor_Bandit_Feet_Armor = 0
Armor_Bandit_Hands_Armor = 0
Armor_Bandit_Head_Armor = 0
Armor_Bandit_Legs_Armor = 0
Armor_Bandit_Torso_Armor = 0
```

---

## windrose_plus.entities.ini

Land and naval entity base stats (creatures, NPCs, bosses). CurveTable: `CT_CharactersAttributes`. Values are absolute.

**91 sections (73 land + 18 naval), 1406 keys total.**

### Land entities (73)

Creatures: `AlphaWolf`, `Boar`, `BoarCharger`, `BoarF`, `BoarFriendLvl2`, `BoarMega`, `Crab`, `Crab_Drowned`, `Crocodile`, `CrocodileCorrupted`, `CrocodileFriend`, `CrocodileWhite`, `Deer`, `Dodo`, `DodoF`, `GoatBig`, `GoatF`, `GoatM`, `Heron`, `Jaguar`, `Wolf`, `Wolf_Ashen`, `Wolf_Ashen_Alpha`

NPCs: `BlackBeard_Heavy_Hooker`, `BlackBeard_Heavy_Marauder`, `BlackBeard_Regular_*` (5 types), `EnglishOfficer`, `EnglishSoldier_*` (2 types), `SenkamatiCorrupted_*` (6 types)

Bosses: `BossIsrael_{1-3}pl_{Easy,Normal,Hard}` (9 variants), `BossToad_{1-3}pl_{Easy,Normal,Hard}` (9 variants), `Boss_Boatswain_{1-3}pl_{Easy,Normal,Hard}` (9 variants)

Other: `Boneman`, `Boneman_Range`, `Drowned_Armored`, `Drowned_Naked`, `Drowned_Spitter`, `Dummy`, `Zombie`

### Naval entities (18)

`Naval_Boar`, `Naval_Crab`, `Naval_Crocodile`, `Naval_CrocodileWhite`, `Naval_Deer`, `Naval_Dodo`, `Naval_DodoF`, `Naval_Dummy`, `Naval_EnglishOfficer`, `Naval_EnglishSoldier_Halberd`, `Naval_EnglishSoldier_Saber`, `Naval_FeralFist`, `Naval_FeralMace`, `Naval_FeralMachete`, `Naval_FeralSaber`, `Naval_Hero`, `Naval_Jaguar`, `Naval_Mosquitos`

### Common stats per entity

Every entity has the same attribute set (key names are unqualified within each section):

| Key | Example (AlphaWolf) | Description |
|-----|---------------------|-------------|
| `Armor` | `25` | Armor value |
| `AttackPwr` | `240` | Attack power |
| `DefencePwr` | `240` | Defence power |
| `Health` | `2240` | Current health |
| `MaxHealth` | `2240` | Maximum health |
| `MaxPosture` | `80` | Maximum posture |
| `MaxStamina` | `100` | Maximum stamina |
| `Posture` | `0` | Starting posture |
| `PostureRegRate` | `10` | Posture regen rate |
| `Stagger` | `0` | Starting stagger |
| `StaggerDefence` | `3` | Stagger defence |
| `Stamina` | `100` | Current stamina |
| `StaminaRegRate` | `75` | Stamina regen rate |

The raw CurveTable key for each is `{EntityName}_{Stat}` (e.g., `AlphaWolf_Armor`).

### Boss scaling pattern

Bosses have separate sections per player count and difficulty: `Boss{Name}_{1-3}pl_{Easy,Normal,Hard}`. Each variant has independent stats, allowing fine-grained difficulty tuning.
