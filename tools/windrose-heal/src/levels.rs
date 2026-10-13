// Vanilla DA_HeroLevels.json extracted from pakchunk0-WindowsServer.pak @ Windrose 0.10.0.2.54,
// re-checked unchanged (all 15 rows) against 0.10.0.9.32 on 2026-10-12.
// Source: R5/Plugins/R5BusinessRules/Content/EntityProgression/DA_HeroLevels.json
// This is the authoritative reward table used by the engine's ValidateData.
// When Windrose ships a game update, re-extract and regenerate this file.

#[derive(Debug, Clone, Copy)]
pub struct LevelEntry {
    pub exp: i64,
    pub talent_points_reward: i32,
    pub stat_points_reward: i32,
}

pub fn vanilla_da_hero_levels() -> Vec<LevelEntry> {
    vec![
        LevelEntry {
            exp: 0,
            talent_points_reward: 0,
            stat_points_reward: 0,
        },
        LevelEntry {
            exp: 600,
            talent_points_reward: 0,
            stat_points_reward: 4,
        },
        LevelEntry {
            exp: 1200,
            talent_points_reward: 2,
            stat_points_reward: 4,
        },
        LevelEntry {
            exp: 1800,
            talent_points_reward: 2,
            stat_points_reward: 4,
        },
        LevelEntry {
            exp: 2400,
            talent_points_reward: 1,
            stat_points_reward: 4,
        },
        LevelEntry {
            exp: 3200,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 4000,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 4800,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 5600,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 6400,
            talent_points_reward: 0,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 7400,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 8400,
            talent_points_reward: 0,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 9400,
            talent_points_reward: 1,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 10400,
            talent_points_reward: 0,
            stat_points_reward: 3,
        },
        LevelEntry {
            exp: 11400,
            talent_points_reward: 1,
            stat_points_reward: 2,
        },
    ]
}

/// Given total XP, return the max level index where Levels[i].exp <= total_exp.
pub fn current_level_index(levels: &[LevelEntry], total_exp: i64) -> usize {
    let mut cur = 0usize;
    for (i, lvl) in levels.iter().enumerate() {
        if total_exp >= lvl.exp {
            cur = i;
        } else {
            break;
        }
    }
    cur
}

/// Sum TalentPointsReward for levels [0..=current_level].
pub fn sum_talent_rewards(levels: &[LevelEntry], current_level: usize) -> i64 {
    levels
        .iter()
        .take(current_level + 1)
        .map(|l| l.talent_points_reward as i64)
        .sum()
}

pub fn sum_stat_rewards(levels: &[LevelEntry], current_level: usize) -> i64 {
    levels
        .iter()
        .take(current_level + 1)
        .map(|l| l.stat_points_reward as i64)
        .sum()
}
