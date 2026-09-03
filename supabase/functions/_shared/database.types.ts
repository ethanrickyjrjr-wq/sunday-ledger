// Minimal hand-written schema for the edge functions (only what `corner` touches).
// Regenerate the real thing once linked:
//   supabase gen types typescript --linked > supabase/functions/_shared/database.types.ts

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export interface Database {
  public: {
    Tables: Record<string, never>
    Views: Record<string, never>
    Functions: {
      fighter_pending: { Args: { p_token: string }; Returns: Json }
      fighter_answer: { Args: { p_token: string; p_battle_id: string; p_answer: string }; Returns: Json }
      fighter_feed: { Args: { p_token: string }; Returns: Json }
      fighter_tape: { Args: { p_token: string; p_battle_id: string; p_text: string }; Returns: Json }
      fighter_record: { Args: { p_token: string }; Returns: Json }
      fighter_identity: {
        Args: { p_token: string; p_tagline: string | null; p_entrance: string | null; p_colors: string | null }
        Returns: Json
      }
      fighter_cite: {
        Args: { p_token: string; p_battle_id: string; p_source_battle: string; p_quote: string; p_cited: string | null }
        Returns: Json
      }
      fighter_claims: { Args: { p_token: string }; Returns: Json }
      fighter_ack: { Args: { p_token: string; p_citation_id: number; p_ok: boolean }; Returns: Json }
      fighter_podium: {
        Args: { p_token: string; p_battle_id: string; p_text: string; p_callout: string | null }
        Returns: Json
      }
      fighter_callouts: { Args: { p_token: string }; Returns: Json }
      fighter_answer_callout: { Args: { p_token: string; p_statement_id: number; p_ok: boolean }; Returns: Json }
      spectator_feed: { Args: { p_token: string }; Returns: Json }
      // The Sunday Ledger (league function)
      league_join: {
        Args: { p_handle: string; p_profile_url: string; p_conference?: string; p_via?: string }
        Returns: Json
      }
      league_claim: { Args: { p_claim_token: string; p_email: string }; Returns: Json }
      league_publish_week: {
        Args: { p_season: number; p_week: number; p_freeze_at: string; p_games: Json; p_main_card: string[] }
        Returns: Json
      }
      league_pick: {
        Args: { p_token: string; p_game_id: string; p_side: string; p_probability: number }
        Returns: Json
      }
      league_week_json: {
        Args: { p_token: string | null; p_season: number | null; p_week: number | null }
        Returns: Json
      }
      league_standings_json: { Args: Record<string, never>; Returns: Json }
      league_settle: { Args: { p_finals: Json }; Returns: Json }
      league_sweep_gate: { Args: Record<string, never>; Returns: Json }
      league_podium_take: {
        Args: { p_token: string; p_season: number; p_week: number; p_text: string }
        Returns: Json
      }
      // Incentives (recognition surfaces)
      league_podiums_json: { Args: Record<string, never>; Returns: Json }
      league_player_card_json: { Args: { p_handle: string }; Returns: Json }
      league_hall_json: { Args: Record<string, never>; Returns: Json }
      league_week_winner: { Args: { p_season: number; p_week: number }; Returns: Json }
      // Props (the second card)
      league_publish_props: { Args: { p_season: number; p_week: number; p_props: Json }; Returns: Json }
      league_prop_pick: {
        Args: { p_token: string; p_prop_id: string; p_side: string; p_probability: number }
        Returns: Json
      }
      league_props_json: {
        Args: { p_token: string | null; p_season: number | null; p_week: number | null }
        Returns: Json
      }
      league_settle_props: { Args: { p_season: number; p_week: number; p_actuals: Json }; Returns: Json }
      league_prop_weeks_unsettled: { Args: Record<string, never>; Returns: Json }
      // Conferences (the signup scoreboard)
      league_conference_counts: { Args: Record<string, never>; Returns: Json }
      // Attribution (house-only): which door each player came through
      league_joins_json: { Args: Record<string, never>; Returns: Json }
      // The Docket + Turn of the Week (record integrity)
      league_dispute_file: {
        Args: {
          p_token: string
          p_game_id: string | null
          p_prop_id: string | null
          p_graded: string
          p_evidence: string
          p_source_url: string
        }
        Returns: Json
      }
      league_dispute_rule: {
        Args: { p_dispute_id: string; p_ruling: string; p_note: string; p_correction: Json | null }
        Returns: Json
      }
      league_correct_game: {
        Args: { p_game_id: string; p_away: number | null; p_home: number | null; p_winner: string | null; p_note: string }
        Returns: Json
      }
      league_correct_prop: {
        Args: { p_prop_id: string; p_actual: number | null; p_void: boolean; p_note: string }
        Returns: Json
      }
      league_turn_credit: {
        Args: { p_token: string; p_game_id: string; p_credited_to: string; p_argument_url: string | null }
        Returns: Json
      }
      league_stamp_turn: {
        Args: { p_season: number; p_week: number; p_handle: string; p_game_id: string; p_note: string | null }
        Returns: Json
      }
      league_docket_json: { Args: Record<string, never>; Returns: Json }
      // Where this week's picks thread lives (20260902223000_picks_post)
      league_picks_post: {
        Args: { p_season?: number | null; p_week?: number | null }
        Returns: Json
      }
      league_set_picks_post: {
        Args: { p_post_id: string; p_season?: number | null; p_week?: number | null }
        Returns: Json
      }
    }
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
