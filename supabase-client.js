// ADbridge — shared Supabase client
// The publishable/anon key is safe to expose in client-side code by design.
const SUPABASE_URL = "https://wxsfervmzbgbsobfwgzg.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_nvSgnAGRqbTkTLKDbaUu-w_4zne8I2Z";

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
  },
});
