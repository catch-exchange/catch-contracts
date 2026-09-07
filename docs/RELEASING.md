# Maintaining the public source record

This repo is an output of reviewed deployments, not an automatic mirror of
private development. Nothing here broadcasts a transaction.

## Publication sequence

1. Establish the source version and already-live addresses covered. Reconcile
   the graph separately from explorer availability.
2. Export only source/dependency closure, licences, ABIs, inputs and sanitized
   identities. Never copy a workspace wholesale.
3. Review every proposed file and commit. Exclude environments, private paths,
   salts, signatures, keystores, transaction bundles, recovery logs and private
   history. Use a GitHub noreply identity.
4. Run integrity tests, exact compilation and redacted secret scans locally.
   Open a focused PR and wait for required CI checks.
5. Preserve published versions. Never rewrite a source tag or imply an edited
   source file changed an already-deployed contract.
6. Create a `source-vX.Y.Z` tag/release at the reviewed public commit. State the
   chain/families covered and checks actually performed. Attach only explicitly
   reviewed public artifacts if needed.
7. Read the repo/release without authentication, then update Catch's docs links.
   Hook applications use exact versioned sources/addresses; routing approval
   remains a separate process.

A new family using unchanged code updates identity evidence/docs without
replacing frozen inputs. New contract versions use separately identified
source layouts; do not rename historical paths merely for tidiness.

## Repository controls

`main` should require the three CI checks, a PR, resolved conversations and
linear history, with force-push/deletion blocked. Zero mandatory peer approvals
is intentional for the current solo maintainer: requiring their own approval
would deadlock releases. CODEOWNERS routes review, not an imaginary independent
reviewer. Add a peer requirement when an independent maintainer exists.

Enable secret scanning, push protection and private vulnerability reporting.
Do not add production keys or RPC credentials as Actions secrets: CI needs none.
Dependabot may propose action updates, never automatic deployed-source changes.

A secret exposure requires revocation/rotation and coordinated cleanup; a
revert or deleted file does not remove copies already made.
