# Gift Exchange

A small, ad-free Christmas gift exchange web app for about 10 people. It works on iPhone (including the iPhone Duo, folded or open) and Android phones like the Galaxy S22+.

- Everyone joins from one invite link you text them, with their first name, last initial and a 4-digit PIN. No email needed.
- Optional profile photo; otherwise their initials show.
- Each person links an **Amazon wish list**, writes a **simple list**, or both, plus an optional mailing address that only their buyer sees.
- The organizer sets "don't pair" rules (spouses) and draws names in one tap.
- Each person sees only who they're buying for, can **ask them anonymous questions**, sees a **"List updated"** tag if their person changes their list, and marks the gift **purchased**.
- The organizer gets a ready-to-send **reminder text**, a **join-by date**, and a **reveal the gift chain** button for the party.
- If the organizer resets someone's PIN, that person is told, so nobody can quietly sign in as someone else.
- A scheduled job keeps the free database awake through the holidays, then stops on its own.

Everything runs on free plans: **Supabase** (database) + **GitHub** (website and keep-alive job). Plan on about 30 minutes, and do it on a computer, not a phone.

---

## 1. Set up the database (Supabase)

1. Make a free account at [supabase.com](https://supabase.com) and click **New project**. Any name and region close to you. Save the database password somewhere, though the app doesn't need it.
2. When the project is ready, open **SQL Editor** → **New query**. Paste everything from `supabase/schema.sql` and click **Run**. It should say "Success".
3. Turn on anonymous sign-ins. They give each phone a hidden login, so nobody needs an email or password. Go to **Authentication** → **Sign In / Providers** (labels may differ slightly), find **Allow anonymous sign-ins**, turn it on, and save.
4. Go to **Project Settings** → **API** (or **API Keys**) and copy two things:
   - **Project URL**, like `https://abcd1234.supabase.co`
   - The **publishable** key (starts with `sb_publishable_`), or the older **anon public** key. Either one works.

Open `config.js` and paste them in:

```js
window.GIFT_CONFIG = {
  SUPABASE_URL: 'https://abcd1234.supabase.co',
  SUPABASE_KEY: 'sb_publishable_...',
};
```

The publishable/anon key is meant to be public. The database only allows the app's own functions, and those enforce the secrecy rules, so it's safe in this file.

## 2. Put the website online (GitHub Pages)

1. Make a free account at [github.com](https://github.com) and create a **new repository** (for example `gift-exchange`). Set it to **Public**, which free GitHub Pages requires. There are no secrets in these files.
2. Click **Add file** → **Upload files** and drag in **everything in this folder**, including the hidden `.github` folder. If your computer hides it, upload `.github/workflows/keepalive.yml` separately with **Add file** → **Create new file** and type that exact path as the name.
3. Go to **Settings** → **Pages**. Under "Build and deployment", choose **Deploy from a branch**, branch **main**, folder **/ (root)**, then **Save**.
4. After a minute, the page shows your site address, like `https://yourname.github.io/gift-exchange/`.

## 3. The keep-alive job

Supabase pauses free projects after 7 days without activity. The included job pings the database every other day until **January 6** and then stops by itself. You can change that date at the top of `.github/workflows/keepalive.yml`.

It reads the database address and public key from `config.js`, so there's nothing to set up. To check it, open the **Actions** tab → **Keep gift exchange awake** → **Run workflow**. A green check means the database and the website both answered.

If a check ever fails, GitHub emails you. The usual fix is to open supabase.com and click **Resume project**.

## 4. Use it

1. Open your site and tap **Start a new exchange**. Enter the name, date, budget, your name and a PIN. You're now the organizer.
2. In the **Organizer** tab, tap **Share invite link** and text it to the group.
3. As people join, add **Don't pair** rules for each couple.
4. When everyone's in, tap **Draw names**. Tell the group to open the link again.
5. Watch the progress. You can see who has looked and who has bought, but never who has whom.
6. After the holidays, tap **Delete this exchange** to erase everything.

### Tips for the group

- **Add to Home Screen.** iPhone: Safari → Share → *Add to Home Screen*. Android: Chrome → ⋮ → *Add to Home screen*.
- **New phone or Home Screen app asks you to join again?** Tap **I already joined**, pick your name and enter your PIN. On iPhone, the Home Screen app keeps its own sign-in separate from Safari, so this is expected the first time.
- **Forgot your PIN?** The organizer can reset it: Organizer tab → ··· next to the name → *Reset PIN*.
- **Someone joins late?** The organizer taps **Add to draw**. That person slots into the loop, and only one other person's assignment changes.
- **Written lists:** one idea per line. A line that's just a web link becomes tappable for whoever is buying for you.
- **Questions:** buyers can ask their person anything from the reveal card. Answers show up for the buyer; the person never learns who asked.
- **Already set up the database before?** Just run `supabase/schema.sql` again in the SQL Editor. It adds the new pieces and keeps your data.

## What's in this folder

| File | What it does |
| --- | --- |
| `index.html` | The whole app (screens, styles, logic) |
| `config.js` | Your Supabase URL and key |
| `manifest.json`, `icon-*.png`, `icon.svg` | Home Screen icon and app name for iPhone and Android |
| `supabase/schema.sql` | Database tables, privacy rules, the draw, and the keep-alive function |
| `.github/workflows/keepalive.yml` | The scheduled job that keeps the database awake |

## How the draw works

Everyone is shuffled into one random loop: A buys for B, B for C, and the last person buys for A. If any neighbors in the loop are a "don't pair" couple, it reshuffles and tries again. The shuffle runs inside the database using its secure random generator, so nobody's phone, including the organizer's, can see or change the result. If the rules make a draw impossible, for example one person blocked from almost everyone, the Organizer tab says so before you draw.
