// ⚙️ Configuration Supabase de R6 Playbook
//
// Où trouver ces deux valeurs : Supabase › ton projet › Project Settings › API Keys
//   SUPABASE_URL : « Project URL »  (ex. https://abcdefgh.supabase.co)
//   SUPABASE_KEY : « Publishable key » (sb_publishable_…) — ou l'ancienne clé « anon »
//
// Elles sont publiques par conception : la sécurité vient des règles RLS
// créées par supabase-setup.sql (lecture pour tous, écriture pour l'admin seulement).
// Ne mets JAMAIS ici la clé « secret » ou « service_role ».

window.R6_CONFIG = {
  SUPABASE_URL: "https://urrzzcwkwbfvjtajwfmd.supabase.co",
  SUPABASE_KEY: "sb_publishable_W5DvoJDVnVfOOPQ5XJ6DtA_nXwbR9PD"
};
