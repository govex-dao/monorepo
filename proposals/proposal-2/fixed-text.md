# Upgrade Govex and Agree on the Upgrade Process

### Introduction
This proposal was created by Gresham to refine permissions for upgrading the Govex futarchy platform smart contract on Sui. This is a multi-option proposal with three options:

• Reject

• One Upgrade

• Multi Upgrade

### Multi upgrade
If "Multi upgrade" is the winning outcome, the operating agreement of Govex DAO LLC will be amended as follows so that the managing member Gresham can upgrade the Govex contract at his discretion. This also details how to handle ongoing proposals when there is a contract upgrade.


##### Operating Agreement Diff
--- Article V.2 (Original)
+++ Article V.2 (Proposed)
@@ -1,6 +1,16 @@
-V.2 **Managing Members.** The Managing Members have the right but not the obligation to make the ordinary and usual decisions concerning the business affairs of the Company, only when:

+V.2 **Managing Members.** The Managing Members have the right but not the obligation to:
 
-1. the Algorithmic Management is unable to represent itself due to technical failures or edge cases.

+(a) Make the ordinary and usual decisions concerning the business affairs of the Company when:

+   1. the Algorithmic Management is unable to represent itself due to technical failures or edge cases.

+   2. or when having a company figurehead is required for the DAO while interfacing with legacy or offline institutions, or when it will likely save time or reduce cost while dealing with such institutions.
 
-2. or when having a company figurehead is required for the DAO while interfacing with legacy or offline institutions, or when it will likely save time or reduce cost while dealing with such institutions. 

+(b) Until the 28th of February 2026, disable new proposal creation without prior notice. After waiting for any live proposals to finalize or by giving four days of notice, whichever is shorter, update any smart contract addresses, package IDs, or other technical identifiers referenced in this Agreement, when necessary to:
+   1. Address security vulnerabilities or bugs
+   2. Maintain operational continuity
+   3. Implement technical improvements
+   
+   Such updates shall be documented and communicated to Members through official venues, with the Agreement deemed automatically amended to reflect new identifiers after four days have passed. As an emergency backup if 30 days have passed since proposal creation was paused any DAO member can redeploy the package in use when the pause began and create a new DAO with the same DAO configs, the first instance of such a package and DAO created that is announced in the official online venue will be automatically deemed the new official DAO ID and the package ID and DAO IDs in V.1 may be updated by any member to match the new identifiers.
 
 The list of initial Managing Members is set forth in "**Exhibit A**."
##### ---  End of diff ---
Gresham personally prefers this outcome as it will save about two days of time, every deployment, and adds clarity to the upgrade process. This new clause V2 B can be repealed at a later date, and Gresham agrees not to take it personally. It is recognised that it add significant centralizing power to the DAO.
### One upgrade
If the "One upgrade" is the winning outcome, the operating agreement of Govex DAO LLC will be amended as to allow the replacement of package ID and DAO ID using the future deployment of the changes made in these git PRs: [1](https://github.com/govex-dao/monorepo/pull/133/files) and [2](https://github.com/govex-dao/monorepo/pull/162/files). The PRs will be deployed onto Sui mainnet and the contract and DAO ID will be updated in the operating agreement with the new ones.


##### Operating Agreement Diff
+++ TEMPORARY ADDITION TO ARTICLE V 

+V.7 The Managing Member can deploy contracts from commit: https://github.com/govex-dao/monorepo/commit/12cc74f742a48a587bab5bcb15653e7984479bb2 and update all package IDs and onchain identifiers in this Agreement. This authority expires on the 31st day of July 2025. This section self-deletes upon expiration.
##### ---  End of diff ---
### Reject
If the "Reject" is the winning outcome, Gresham will not deploy anything without further discussion and feedback from the community and a new proposal. This option leaves the DAO vulnerable to issues noticed with the TWAP contract and will slow down our execution speed, as other code changes already depend on the contract upgrade.
