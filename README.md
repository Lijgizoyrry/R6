# R6 Playbook

Ta base perso de stratégies **Rainbow Six Siege** (tricks, placements, lignes de tir) : **Carte › Camp › BP › Vidéo**, en trois touches, avec le logo de l'agent sur chaque stratégie. Pas un outil de triche : juste tes vidéos, bien rangées.

- **PWA en fichier unique** (`index.html`), installable sur l'iPhone, utilisable sur PC.
- **Supabase** pour la base, la connexion et le stockage des logos. **Vercel** pour l'hébergement, relié à **GitHub**.
- Vidéos YouTube, **Shorts** et fichiers `.mp4/.webm`, **sans limite**, lues sur place.

---

## Mise en ligne (≈ 10 min, faisable depuis l'iPhone)

### 1. Supabase — la base
1. Sur [supabase.com](https://supabase.com) : **New project** (région conseillée : *West EU (Paris)*).
2. **SQL Editor › New query** : colle tout le contenu de `supabase-setup.sql`, puis **Run**.
   → crée les tables, la sécurité, le stockage des logos et pré-remplit 18 cartes, 72 BP et 78 agents.
3. **Authentication › Users › Add user › Create new user** : ton email + un mot de passe, coche **Auto Confirm User**.
   → le premier compte créé devient **admin** automatiquement.
4. *(Conseillé)* **Authentication › Sign In / Providers** : désactive **Allow new users to sign up**.
5. **Project Settings › API Keys** : garde sous la main la **Project URL** et la **Publishable key** (`sb_publishable_…`).

### 2. GitHub — le code
1. Crée un dépôt (ex. `r6-playbook`, privé ou public).
2. **Add file › Upload files** : envoie **tous les fichiers du dossier** (ils sont à plat, pas de sous-dossier).
3. Ouvre `config.js` dans GitHub (crayon ✏️), colle l'URL et la clé publishable entre les guillemets, **Commit**.

### 3. Vercel — le site
1. Sur [vercel.com](https://vercel.com) : **Add New › Project › Import** ton dépôt GitHub.
2. Framework : **Other**. Aucune commande de build. **Deploy**.
3. Chaque modification poussée sur GitHub redéploie le site tout seul.

> Oublié `config.js` ? Le site affiche un écran « Connecte ta base » : colle l'URL et la clé, c'est mémorisé sur l'appareil.

### 4. Sur l'iPhone
Safari › bouton Partager › **Sur l'écran d'accueil** : l'app s'ouvre en plein écran, comme une app native.

---

## Utilisation

- **Naviguer** : Carte › Attaque/Défense › BP › touche une vidéo. Glisse vers la droite pour revenir ; dans le lecteur, glisse vers le bas pour fermer, à gauche/droite pour passer à la vidéo suivante.
- **Se connecter** : icône 👤 en haut à droite. Une pastille verte = mode gestion actif.
- **Ajouter une vidéo** : sur un BP, bouton **Ajouter**. Colle le lien (YouTube, `youtu.be`, `/shorts/`, `.mp4`) : le titre, le format Short/16:9 et le temps de départ (`?t=`) sont détectés. Choisis l'agent (logo), le type, une **fin de boucle** si tu veux répéter un passage précis.
- **Modifier, épingler, partager, supprimer** : bouton **⋯** sur la carte vidéo. La suppression demande un second appui.
- **Gérer cartes, BP et agents** : menu 👤 › Gérer… (ajouter une carte, masquer une carte hors pool, renommer, changer les étages des BP, etc.).
- **Récents** : tes derniers BP ouverts sont en tête de l'accueil.

### Logos officiels des agents
Les logos Ubisoft ne sont **pas inclus** dans le projet. Ajoute-les depuis **👤 › Agents et logos** :
- **Importer des logos** : sélectionne tous tes fichiers d'un coup ; chaque fichier doit porter le nom de l'agent (`thermite.png`, `jager.svg`, `solid-snake.webp`…). Ils sont redimensionnés puis rangés dans Supabase Storage.
- ou touche le rond d'un agent pour changer un logo à l'unité ;
- ou **Modèle d'URL** si tes logos sont déjà en ligne avec des noms réguliers (`https://…/{slug}.png`).
En attendant, un badge à initiales aux couleurs du camp s'affiche.

### Lecteur
- Un **seul lecteur YouTube préchargé** dès que tu choisis une carte : au clic, la vidéo démarre dans la seconde, sur place, sans passer par YouTube.
- Vitesse **¼× ½× 1×**, **boucle**, son, vidéo précédente/suivante. Si le navigateur bloque la lecture avec son (iPhone), elle démarre en muet avec un bouton « Activer le son ».
- Si l'auteur d'une vidéo a interdit sa lecture sur d'autres sites, le lecteur l'indique et propose de l'ouvrir sur YouTube.

### Raccourcis clavier (PC)
| Où | Touches |
|---|---|
| Partout | `Échap` ou `Retour arrière` : revenir |
| Cartes | tape une lettre pour chercher |
| Camp | `A` attaque, `D` défense |
| BP / vidéos | `1` à `9` |
| Lecteur | `←` `→` vidéo préc./suiv., `Espace` pause, `L` boucle, `M` son, `1` `2` `3` vitesse |

---

## Architecture de la base Supabase

```
maps (cartes) ──< sites (BP) ──< strategies (vidéos) >── operators (agents)
                                        │
admins (comptes autorisés à modifier)   └─ 1 ligne = 1 vidéo, autant que tu veux par BP
storage « media » : logos d'agents et images de cartes
```

| Table | Colonnes clés | Rôle |
|---|---|---|
| `maps` | `slug` (unique), `name`, `image_url`, `is_active`, `sort_order` | Les cartes. `is_active = false` masque une carte sortie du pool sans perdre ses vidéos. |
| `sites` | `map_id` → maps, `name`, `floor` (B, 1F, 2F…), `sort_order` | Les BP d'une carte. Unique par (`map_id`, `name`). Suppression en cascade. |
| `operators` | `slug` (unique), `name`, `side` (`attack`/`defense`), `icon_url` | Les agents et leur logo. |
| `strategies` | `site_id` → sites, `side`, `operator_id` → operators, `title`, `category`, `notes`, `video_url`, `provider` (`youtube`/`file`), `video_id`, `kind` (`video`/`short`), `start_seconds`, `end_seconds`, `pinned` | Une vidéo rangée sur un BP, pour un camp, avec l'agent requis (ou aucun). |
| `admins` | `user_id` → auth.users | Comptes qui ont le droit d'écrire. |

**Règles et garde-fous**
- **RLS** sur toutes les tables : lecture publique (le site s'affiche sans connexion), ajout/modification/suppression réservés aux admins via la fonction `is_admin()`.
- Un déclencheur refuse un agent du mauvais camp (ex. Smoke sur une stratégie d'attaque).
- Contraintes : identifiant YouTube valide (11 caractères), fin de boucle après le début, types de catégorie fixés.
- Supprimer une carte supprime ses BP et leurs vidéos ; supprimer un agent garde ses vidéos (sans agent).
- Le script est **ré-exécutable** : relance-le sans risque après une mise à jour, il ne touche pas à tes vidéos.

---

## Choix techniques (vitesse)
- **Lecture directe** de la base via l'API REST Supabase (une seule requête par table, en parallèle, paginée par 1000 : aucune limite de quantité).
- **Cache local + service worker** : l'app s'ouvre instantanément avec les dernières données, puis se met à jour en arrière-plan ; elle reste consultable hors ligne.
- **supabase-js n'est chargé que pour la gestion** (connexion, ajout, suppression) : les visiteurs ne téléchargent rien de superflu.
- Navigation entièrement locale (pas de rechargement), historique et liens partageables : `?carte=clubhouse&camp=attaque&bp=…&video=…`.

## Bon à savoir
- **Offre gratuite Supabase** : un projet sans activité pendant environ une semaine est mis en pause. L'app continue d'afficher les données en cache ; réactive le projet depuis le tableau de bord Supabase (« Restore »).
- Les cartes pré-remplies sont celles des pools classés de l'Année 11 (vérifiées en octobre 2026, Villa après la mise à jour Split Fire). Le pool tourne souvent : ajoute, masque ou renomme depuis le mode gestion.
- Les clés dans `config.js` sont publiques par conception. **Ne mets jamais** la clé `secret`/`service_role` dans le site.

## Fichiers
| Fichier | Rôle |
|---|---|
| `index.html` | Toute l'application (interface, navigation, lecteur, gestion) |
| `config.js` | Tes deux valeurs Supabase |
| `supabase-setup.sql` | Tables, sécurité, stockage et données de départ |
| `sw.js`, `manifest.webmanifest`, `icon-*.png`, `apple-touch-icon.png` | PWA (installation, hors ligne, icônes) |
| `vercel.json` | En-têtes de cache et de sécurité pour Vercel |
