# TestFlight from GitHub Actions, step by step

This gets SkyForge onto your iPhone, iPad and Mac through TestFlight, with no Mac of your own. GitHub builds and signs the app on a Mac in the cloud, then uploads it to App Store Connect. You do the Apple and GitHub clicks below once. After that, each build is one button press.

Nothing here needs a password or key pasted into chat. You create the keys yourself and add them to GitHub as secrets. Keep every key and password private.

## What you need

- An **Apple Developer Program** membership (paid, yearly). Enrol at developer.apple.com/programs.
- Admin access to this GitHub repository.
- Any computer with `openssl` for step 6. Linux, Windows with Git Bash or WSL, or a cloud shell all work.

Time: about 45 minutes the first time, then about 30 minutes per build while GitHub and Apple work.

---

## Step 1. Pick your bundle ID

The bundle ID is a unique name for the app, written in reverse domain style. Pick one you control, for example `com.yourname.skyforge`. Write it down. You will enter it in three places: the Apple developer site (step 2), App Store Connect (step 3), and GitHub (step 7). It must match exactly.

## Step 2. Register the bundle ID

1. Go to developer.apple.com, then **Certificates, Identifiers & Profiles**.
2. Click **Identifiers**, then the **+** button.
3. Choose **App IDs**, then **App**, then **Continue**.
4. Description: `SkyForge`. Bundle ID: **Explicit**, then your bundle ID from step 1.
5. Leave the capabilities as they are. SkyForge only needs the App Sandbox and network access, which are on by default.
6. Click **Continue**, then **Register**.

## Step 3. Create the app in App Store Connect

1. Go to appstoreconnect.apple.com, then **Apps**, then **+**, then **New App**.
2. Tick **iOS** and **macOS**. (One app record covers both.)
3. Name: `SkyForge`. If Apple says the name is taken, choose another name, such as `SkyForge Flight Sim`.
4. Primary language: English (U.S.) or your choice.
5. Bundle ID: pick the one you registered in step 2.
6. SKU: any text that is unique to you, such as `skyforge-2026`. Apple never shows it to players.
7. User Access: **Full Access**. Click **Create**.

## Step 4. Note your Team ID

1. Go to developer.apple.com, then **Membership details**.
2. Copy the **Team ID**. It is 10 letters and digits. This becomes the secret `APPLE_TEAM_ID`.

## Step 5. Create the App Store Connect API key

GitHub uses this key to upload builds and to set up signing automatically.

1. In App Store Connect, go to **Users and Access**, then **Integrations**, then **App Store Connect API**.
2. Open the **Team Keys** tab and click **Generate API Key** (or the **+** button).
3. Name: `github-actions`. Access: **App Manager**. Click **Generate**.
   If a later run says permission denied while signing, delete this key and make another with **Admin** access.
4. Write down three things from that page:
   - **Key ID**, in the table. This becomes the secret `ASC_KEY_ID`.
   - **Issuer ID**, at the top of the page. This becomes the secret `ASC_ISSUER_ID`.
   - Click **Download API Key**. You get a file named `AuthKey_XXXXXXXX.p8`. Apple lets you download it **once only**. Keep it safe.
5. Turn the `.p8` file into one line of text. On your computer:
   ```
   base64 -w0 AuthKey_XXXXXXXX.p8
   ```
   (On a Mac it is `base64 -i AuthKey_XXXXXXXX.p8 | tr -d '\n'`.) Copy the output. This becomes the secret `ASC_KEY_BASE64`.

## Step 6. Create the distribution certificate (no Mac needed)

The certificate proves that the builds came from you. You make a key pair and a request on your own computer, and Apple signs it.

1. Make a folder, then create the key and the request:
   ```
   mkdir skyforge-signing && cd skyforge-signing
   openssl req -new -newkey rsa:2048 -nodes -keyout distribution.key \
     -out CertificateSigningRequest.certSigningRequest -subj "/CN=SkyForge Distribution"
   ```
2. Go to developer.apple.com, then **Certificates**, then **+**.
3. Choose **Apple Distribution**, then **Continue**. Upload `CertificateSigningRequest.certSigningRequest`, then **Continue**, then **Download**. You get `distribution.cer`. Put it in the same folder.
4. Turn the certificate into a `.p12` file. Pick a long password and keep it for step 7:
   ```
   openssl x509 -inform DER -in distribution.cer -out distribution.pem
   openssl pkcs12 -export -legacy -inkey distribution.key -in distribution.pem \
     -out distribution.p12 -passout pass:CHOOSE-A-LONG-PASSWORD
   ```
   The `-legacy` flag matters. Without it, the macOS runner cannot import the file and fails with "MAC verification failed".
5. Turn the `.p12` into one line of text:
   ```
   base64 -w0 distribution.p12
   ```
   The output becomes the secret `BUILD_CERTIFICATE_BASE64`. The password becomes `P12_PASSWORD`.
6. Keep `distribution.key` and the `.p12` safe. Delete the `.p8` and `.p12` files from your computer after you add them to GitHub.

The certificate lasts one year. To renew, repeat step 6 and update the two secrets.

## Step 7. Add the secrets and variable to GitHub

1. In the repo, go to **Settings**, then **Environments**, then **New environment**. Name it exactly `release`.
2. Under **Required reviewers**, add yourself. Under **Deployment branches**, choose **Selected branches** and add `main`. Save.
3. In the `release` environment, under **Environment secrets**, add these six secrets:

   | Secret | Value from |
   |---|---|
   | `APPLE_TEAM_ID` | Step 4 |
   | `ASC_KEY_ID` | Step 5 |
   | `ASC_ISSUER_ID` | Step 5 |
   | `ASC_KEY_BASE64` | Step 5, item 5 |
   | `BUILD_CERTIFICATE_BASE64` | Step 6, item 5 |
   | `P12_PASSWORD` | Step 6, item 4 |

4. Under **Environment variables**, add one variable:

   | Variable | Value |
   |---|---|
   | `APP_BUNDLE_ID` | Your bundle ID from step 1 |

The app's bundle ID in the project file stays as it is. The variable overrides it for signed builds, so you never need to edit the Xcode project.

## Step 8. Run a TestFlight build

1. In the repo, go to **Actions**, then **Release archive**, then **Run workflow**.
2. Branch: `main`. Tick **Sign and export** and **Upload the signed builds to TestFlight**. Click **Run workflow**.
3. The run waits for approval. Open it, click **Review deployments**, tick `release`, then **Approve and deploy**. (You are the reviewer, so this is your own approval.)
4. Wait for both jobs, `archive (ios)` and `archive (macos)`, to finish. They take about 20 to 40 minutes. A green run means Apple has the builds.

## Step 9. Install it with TestFlight

1. In App Store Connect, open **Apps**, then **SkyForge**, then **TestFlight**. The new build shows as **Processing** for 10 to 60 minutes, then it is ready.
2. Add yourself as a tester: **Internal Testing**, then **+** to make a group, then add your Apple ID. Internal testers need no Apple review, and you can test the build right away.
3. Install the app:
   - **iPhone or iPad:** install **TestFlight** from the App Store, sign in with the same Apple ID, then tap **Install** on SkyForge.
   - **Mac:** install **TestFlight** from the Mac App Store, then install SkyForge from it.
4. External testers (people outside your team) need one Beta App Review the first time. It usually takes about a day.

Each run gets a new build number automatically, because the build number is the GitHub run number. To send a new build, run step 8 again.

## Troubleshooting

| What you see | What to do |
|---|---|
| The run never asks for approval, or the job is skipped | Check you ticked **Sign and export**, and that the branch is `main`. |
| `preflight` fails with "bundle ID ... placeholder" | Add the `APP_BUNDLE_ID` variable in the `release` environment (step 7.4). |
| `security import` says "MAC verification failed" | Redo step 6 and keep the `-legacy` flag. |
| Signing says "No Account for Team" or "Failed to authenticate" | Check `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and that `ASC_KEY_BASE64` is the whole `.p8` file. The key must be a Team key, not revoked. |
| Signing says "permission denied" or "no profiles" | Make the API key with **Admin** access (step 5, item 3), then update the secrets. |
| Signing says the bundle ID is not registered | The bundle ID in `APP_BUNDLE_ID` must match step 2 exactly. |
| Upload fails with "app record not found" | Finish step 3, with the same bundle ID. |
| Upload fails with an authentication error | `ASC_KEY_ID` must match the `.p8` file name. Check the key has not been revoked. |
| The build is missing in TestFlight after an hour | Open **Activity** in App Store Connect. Apple emails you if processing failed and shows the reason. |

## What this does not do

- It does not submit the app to the App Store. That is a separate step in App Store Connect, after TestFlight testing.
- It does not fill in the store listing, screenshots, privacy answers, or age rating. See `docs/appstore/OWNER_TODO.md`.
- It does not run on your phone. Test on real hardware, as described in `docs/MAC_DAY.md`.

Never paste a `.p8`, `.p12`, `.key`, or password into a chat, issue, or commit. If one leaks, revoke it in Apple Developer or App Store Connect straight away, then make a new one.
