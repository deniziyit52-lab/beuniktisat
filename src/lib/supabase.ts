import { createClient } from "@supabase/supabase-js";

const supabaseUrl =
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  "https://zhjdbpokoyitvwlkncdd.supabase.co";
const supabaseAnonKey =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpoamRicG9rb3lpdHZ3bGtuY2RkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExODYyMzEsImV4cCI6MjEwNjc2MjIzMX0.Za4vf8mDR2xOKxXSKAipO0_-21Yk_vHiVUm5nlH1ZnY";

export const supabase = createClient(supabaseUrl, supabaseAnonKey);