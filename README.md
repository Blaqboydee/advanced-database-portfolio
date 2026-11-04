# Advanced Database Systems Portfolio – OwoTrust Digital Bank

- **Course:** MIT 8103 Advanced Database Systems, MIVA Open University (2026/2027, First Semester CA)
- **Student:** Adeoluwa Adegoke
- **Matric No:** _<fill in>_

---

## Selected case study

| Item | Details |
|---|---|
| **Organisation** | **OwoTrust Digital Bank**: a *simulated* Nigerian retail bank and fintech platform. The name and all data are fictional. |
| **Nature of the business** | Retail banking through five physical branches (Lagos Island, Ikeja, Abuja, Ibadan and Port Harcourt) plus a mobile app. It offers naira savings and current accounts and USD domiciliary accounts. Money moves through branch, mobile, web, USSD, ATM and POS channels. |
| **Users of the database** | Customers (through the app, web and USSD), tellers, customer-service staff, branch managers, compliance officers, auditors, and automated batch jobs (fees and interest) |
| **Major data stored** | Customers (BVN, contact details, KYC tier), branches, staff, account products, accounts and joint ownership, deposits, withdrawals, transfers, fees, reversals and transaction status history |
| **Key operations** | Open an account, deposit, withdraw, transfer funds, reverse a failed or mistaken transaction, charge fees, produce an account statement, and audit account balances against transaction history |

The same case study is used in all five portfolio activities.

**ER diagram:** see [Portfolio 1, section 2](portfolio-1-database-design/README.md#2-er-diagram).

---

## Portfolio activities

| # | Activity | Folder | Status |
|---|---|---|---|
| 1 | Database Design and Modelling | [portfolio-1-database-design/](portfolio-1-database-design/) | ✅ Complete |
| 2 | Query Processing and Optimisation | [portfolio-2-query-optimisation/](portfolio-2-query-optimisation/) | ⏳ Planned |
| 3 | Transactions and Concurrency | [portfolio-3-transactions-concurrency/](portfolio-3-transactions-concurrency/) | ⏳ Planned |
| 4 | NoSQL and Advanced Data Models | [portfolio-4-nosql/](portfolio-4-nosql/) | ⏳ Planned |
| 5 | Distributed and Cloud Database | [portfolio-5-distributed-cloud/](portfolio-5-distributed-cloud/) | ⏳ Planned |

Each folder has its own README explaining what was built, how it was tested, and where the evidence is.

---

## Technology

| Tool | Used for |
|---|---|
| PostgreSQL 16 (Docker image `postgres:16`) | Relational database for Portfolios 1–3 |
| Docker / Docker Compose | Reproducible local environment ([docker-compose.yml](docker-compose.yml)) |
| Mermaid | ER diagram, rendered by GitHub |
| *(planned)* MongoDB, Redis | NoSQL models (Portfolio 4) |
| *(planned)* PostgreSQL streaming replication / MongoDB replica set | Distributed exercise (Portfolio 5) |

## Running the project

Prerequisite: Docker Desktop.

```bash
docker compose up -d                          # PostgreSQL on localhost:5433 (user owotrust)
./portfolio-1-database-design/run_all.sh      # build + seed + test Portfolio 1
docker exec -it owotrust-pg psql -U owotrust -d owotrust_bank   # interactive SQL shell
```

## Repository structure

```
advanced-database-portfolio/
├── docker-compose.yml
├── portfolio-1-database-design/      schema, seed data, constraint tests, ER diagram, normalisation
├── portfolio-2-query-optimisation/
├── portfolio-3-transactions-concurrency/
├── portfolio-4-nosql/
├── portfolio-5-distributed-cloud/
└── README.md
```

---

## AI use declaration

_To be completed by the student before submission._

- **Tool used:** Claude Code (Anthropic), running in VS Code
- **What it was used for:** _<e.g. explaining the brief, drafting SQL scripts and documentation, suggesting test cases>_
- **How the output was reviewed and verified:** _<e.g. ran every script against PostgreSQL myself, checked balances by hand, modified X, rejected Y, …>_

## References

- PostgreSQL Global Development Group (2024) *PostgreSQL 16 Documentation*. https://www.postgresql.org/docs/16/
- Central Bank of Nigeria (2013) *Circular on the Three-Tiered Know Your Customer (KYC) Requirements*. Used as the basis for the `kyc_tier` table. The limit values in this project are illustrative.
- Elmasri, R. and Navathe, S. B. (2016) *Fundamentals of Database Systems*. 7th edn. Pearson. Used for normalisation (1NF–BCNF).
