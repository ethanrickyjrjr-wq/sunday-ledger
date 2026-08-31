import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined

export const authConfigured = Boolean(url && key)

// When unconfigured we still build a client against a placeholder so the app
// can render the setup screen instead of crashing at import time.
export const supabase = createClient(url ?? 'https://placeholder.supabase.co', key ?? 'placeholder')
