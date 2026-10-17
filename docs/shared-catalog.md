# One catalog, separate opinions

StreamVibes connects each Mac directly to one PostgreSQL database. People using
that same database see the same titles, watch lists and shared watched status.
Each review belongs to an app profile, so you can rate the same title differently.

## A typical movie night

1. Connect both Macs to the same dedicated catalog database.
2. Create a profile for each person, or select an existing profile.
3. Add a title in Catalog. AI and movie-provider keys are optional.
4. Choose New List and give it a name such as Friday Movie Night.
5. Inside the list, choose Add Item → Existing Item to reuse catalog titles.
6. Right-click a movie and choose Mark as Watched. The card and list progress update.
7. Choose Quick Review, set a score from 0 to 10, add your review and save.
8. Each person uses their own profile to leave their own score and review.
9. Open the title from Catalog to compare reviews and discuss it in comments.

Watched status is shared across the catalog. It is not a separate watch-history
ledger for each person. Ratings and reviews are attributed separately. Do not use
Complete List just to mark one movie: completing a list removes its unwatched
entries after confirmation. Use Watched for individual titles instead.

## Hosted PostgreSQL with Neon

[Neon](https://neon.com/docs/connect/connect-from-any-app) is a practical hosted
PostgreSQL option for a small trusted group. Other managed PostgreSQL services or
a self-hosted server also work when they meet the app's TLS and extension needs.
This guide is based on Neon's documentation; it is not a Neon certification or a
claim that this build was tested against a live Neon account.

1. Create a dedicated database for StreamVibes, separate from other projects.
2. Use Neon's Connect dialog to choose the database and branch. Everyone must use
   the same database and branch; a new branch is an independent catalog copy.
3. For the initial small desktop setup, use the direct PostgreSQL endpoint.
   The app has its own connection pool and runs schema migrations on connection.
   Evaluate pooled endpoints separately before promising compatibility.
4. The initial connection needs permissions for tables and
   [pg_trgm](https://neon.com/docs/extensions/pg_trgm). The app applies 21 migrations.
5. Enter the connection URL privately in StreamVibes on each participating Mac.
   Keep `sslmode=verify-full` or `sslmode=require`; this app verifies the certificate
   and hostname for either value. Connection URLs are saved in macOS Keychain.
6. Create or select a different profile on each Mac. Catalog and list summaries
   refresh every 30 seconds, or manually with Command-R. Open a list again to reload
   its membership; current list membership is not a live subscription.

The URL parser supports `sslmode` and optional `sslrootcert`. Other connection-URL
options are not applied by this build. In particular, do not assume that a copied
`channel_binding` or timeout parameter enforces a policy inside StreamVibes.

## Share access deliberately

Use this direct-database design with people you trust to access and edit the whole
catalog. Profiles are display identities, not passwords, private accounts, invite
links or row-level permissions. Anyone with a database credential can act with
that role's privileges, including outside the app.

Do not distribute an owner credential for a Neon project containing unrelated
databases. Neon's console-created roles inherit elevated privileges; use
[scoped SQL roles](https://neon.com/docs/manage/database-access) when provisioning
non-administrative access. This build runs migrations on every connection, so do
not promise that a limited runtime role works without checking its migration
permissions first. Separate migrator/runtime roles and real invitations are future
product work, not features this version already implements.

Keep connection URLs out of screenshots, issues and videos. Use a disposable
catalog with fictional profiles and titles when recording a demo. Neon plans,
limits, restore windows and costs depend on the current plan; check them in Neon
before choosing a plan. No paid plan is required by StreamVibes itself.
