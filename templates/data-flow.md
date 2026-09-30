# Data flow — <repo> (reviewed by counsel before launch)
| Data | Collected from | Stored where | Sent to | Why | Retention |
|---|---|---|---|---|---|
| Telegram user ID | Telegram initData | Ethiopian DB | Telegram (to open app, deliver opted-in reminders) | Login, reminders | Until account deletion |
| Display name | User choice in app (not taken from Telegram by default) | Ethiopian DB | nobody | Leaderboards | Until deletion |
| Phone (only if OTP used, D3) | User | Ethiopian DB | local SMS provider | OTP | Until deletion |
| Picks, points, groups | App | Ethiopian DB | nobody | Game | Until deletion |
| Logs | Server | Ethiopian log store | nobody | Operations | 30 days; fields per standards/docs/05 rule 6 |
Foreign services in the flow: Telegram only. Anything else needs a founder decision and counsel review.
