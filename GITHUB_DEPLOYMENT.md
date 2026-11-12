# Publish UniWear on GitHub Pages

This project includes `.github/workflows/deploy.yml`. It builds Flutter Web and deploys it to GitHub Pages whenever code is pushed to `main`.

## 1. Create the GitHub repository

1. Sign in at https://github.com/new.
2. Create a repository named `uniwear` (or another name you prefer).
3. Choose **Private** or **Public**. GitHub Pages availability and limits depend on your GitHub plan and repository visibility.
4. Do not initialize the repository with a README, license, or `.gitignore` because this project already contains those files.

## 2. Upload this project

From the project folder, run:

```bash
git init
git add .
git commit -m "Prepare UniWear Flutter app"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/uniwear.git
git push -u origin main
```

Replace `YOUR-USERNAME` and `uniwear` with the actual GitHub account and repository name. If Git asks you to sign in, complete GitHub's browser/device authentication; do not put a password or token in the remote URL.

## 3. Add the Supabase build settings

In GitHub, open the repository → **Settings → Secrets and variables → Actions**.

- Under **Variables**, create `SUPABASE_URL` with the Supabase Project URL.
- Under **Secrets**, create `SUPABASE_PUBLISHABLE_KEY` with the Supabase publishable key.

Use only the publishable key in this Flutter web client. Never add the Supabase `service_role` key or a secret key to GitHub Actions variables, source files, or browser builds.

## 4. Enable GitHub Pages

1. Open repository **Settings → Pages**.
2. Under **Build and deployment → Source**, choose **GitHub Actions**.
3. Open the **Actions** tab and watch **Build and deploy UniWear Web**.

The first deployment runs after the push to `main`. Later pushes deploy automatically. You can also run it manually from **Actions → Build and deploy UniWear Web → Run workflow**.

## 5. Find the website URL

For a repository named `uniwear`, the URL is:

`https://YOUR-USERNAME.github.io/uniwear/`

The workflow calculates the repository subpath automatically, so the repository does not have to be named `uniwear`.

After the first successful deployment, add the exact website URL to Supabase **Authentication → URL Configuration** as the Site URL and an allowed redirect URL. Configure mobile deep links separately if Android/iOS builds will use password recovery or email confirmation.

## Notes

- The workflow generates the missing Flutter `web/` scaffold on the GitHub runner; you do not need Flutter installed on your computer to publish from GitHub.
- GitHub Pages hosts the web client only. It does not host the Supabase database or replace Android/iOS builds.
- If the workflow fails, open the failed run in **Actions** and inspect the first failing step.
