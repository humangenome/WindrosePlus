# Tests for the item catalog's stat labels (tools/lib/StatLabels.ps1).
# Run: pwsh -File scripts/Test-StatLabels.ps1   (or Windows PowerShell 5.1)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\lib\StatLabels.ps1')
$failed = 0
$cases = @(
    @('AttackPower', '', 'Attack power'),
    @('ShipFireRangeRANK', '', 'Ship range'),
    @('ShipFireAccuracyRANK', '', 'Ship accuracy'),
    @('ShipCannonReloadTime', '', 'Ship reload'),
    @('Defence', '', 'Defence'),
    @('Mastery', 'Some_Row', 'Mastery'),
    @('', 'Greatsword_Souldrinker_AbilityCooldown', 'Ability cooldown'),
    @('', 'Food_Raw_UmbraFruit_T03_Duration', 'Duration'),
    @('', 'Vanilla_SetEffect_CritChance', 'Critical chance'),
    @('', 'Vanilla_SetEffect_CritDamageAdd', 'Critical damage bonus'),
    @('', 'Vanilla_SetEffect_CritDamageMax_UI', 'Critical damage max'),
    @('', 'Bandit_SetEffect_DmgResist', 'Damage resistance'),
    @('', 'Pikeman_SetEffect_ExtraHP', 'Extra health'),
    @('', 'Flibustier_SetEffect_AttackStaminaCons', 'Attack stamina use'),
    @('', 'Pikeman_SetEffect_MeleeDmgBonus', 'Melee damage bonus'),
    @('', 'Ring_CritChance_StatValue', 'Critical chance'),
    @('', 'ColdBarrels_Advanced_Weakspot', 'Weakspot'),
    @('', 'Cutlass_WpnCritChanceBonus', 'Weapon critical chance bonus'),
    @('', 'Item_StmnCons', 'Stamina use'),
    @('', 'Item_CrptTickResist', 'Corruption tick resistance'),
    @('', 'Item_PostureBonusAdd', 'Posture bonus'),
    @('', 'Item_Effect1', 'Effect'),
    @('', 'Item_TotalHealthResotre', 'Total health restore'),
    @('', 'Item_DPS', 'DPS'),
    @('', '30', 'Value'),
    @('', '2.5', 'Value'),
    @('None', 'None', 'Value'),
    @('', '', 'Value')
)
foreach ($c in $cases) {
    $got = Get-WindroseStatLabel $c[0] $c[1]
    if ($got -ceq $c[2]) { Write-Host "ok   '$($c[0])' '$($c[1])' -> $got" }
    else { $failed++; Write-Host "FAIL '$($c[0])' '$($c[1])' -> '$got', expected '$($c[2])'" }
    if ($got -match '_' -or $got -cnotmatch '^[A-Z]') { $failed++; Write-Host "FAIL '$got' has an underscore or no capital first letter" }
}
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host "All stat label tests passed."
