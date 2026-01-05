-- Monthly aggregation of all payments by user (user_id + payment_month)
WITH monthly_revenue AS (
    SELECT
        gp.user_id,
        DATE_TRUNC('month', gp.payment_date)::date AS payment_month,
        SUM(COALESCE(gp.revenue_amount_usd, 0)) AS total_revenue
    FROM project.games_payments AS gp
    GROUP BY gp.user_id, DATE_TRUNC('month', gp.payment_date)
),
-- User profile: first and last paid month and LTV (total revenue across all months)
user_profile AS (
    SELECT
        user_id,
        MIN(payment_month) AS first_payment_month,
        MAX(payment_month) AS last_payment_month,
        SUM(total_revenue)::bigint AS ltv
    FROM monthly_revenue
    GROUP BY user_id
),
-- Calendar of months (from the minimum to the maximum month in the data)
months_range AS (
    SELECT
        (DATE_TRUNC('month', MIN(payment_month))::date) AS min_month,
        (DATE_TRUNC('month', MAX(payment_month))::date) AS max_month
    FROM monthly_revenue
),
calendar AS (
    SELECT generate_series(min_month, max_month, interval '1 month')::date AS calendar_month
    FROM months_range
),
-- For each user, include all months (calendar) -> allows identifying churn / return from churn
user_months AS (
    SELECT
        u.user_id,
        c.calendar_month AS payment_month
    FROM (SELECT DISTINCT user_id FROM monthly_revenue) u
    CROSS JOIN calendar c
),
-- Join actual monthly revenue (0 if the user did not pay)
user_months_with_revenue AS (
    SELECT
        um.user_id,
        um.payment_month,
        COALESCE(mr.total_revenue, 0) AS total_revenue
    FROM user_months um
    LEFT JOIN monthly_revenue mr
        ON um.user_id = mr.user_id
        AND um.payment_month = mr.payment_month
),
-- Comparison of months for each user (previous month and its revenue),
-- as well as additional helper fields (paid flags, last payment before the current month)
settlement_months AS (
    SELECT
        umwr.user_id,
        umwr.payment_month,
        umwr.total_revenue,
        LAG(umwr.total_revenue) OVER (PARTITION BY umwr.user_id ORDER BY umwr.payment_month) AS previous_month_revenue,
        LAG(umwr.payment_month) OVER (PARTITION BY umwr.user_id ORDER BY umwr.payment_month) AS previous_month,
        CASE WHEN umwr.total_revenue > 0 THEN 1 ELSE 0 END AS paid,
        CASE WHEN LAG(umwr.total_revenue) OVER (PARTITION BY umwr.user_id ORDER BY umwr.payment_month) > 0 THEN 1 ELSE 0 END AS previous_paid,
        MAX(CASE WHEN umwr.total_revenue > 0 THEN umwr.payment_month ELSE NULL END)
            OVER (PARTITION BY umwr.user_id ORDER BY umwr.payment_month
                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS last_paid_before_current
    FROM user_months_with_revenue umwr
),
-- Calculation of economic metrics at the user + payment_month level
metrics AS (
    SELECT
        sm.user_id,
        sm.payment_month AS "Date",
        -- PAID USERS: 1 якщо користувач платив цього місяця, інакше 0
        (CASE WHEN sm.paid = 1 THEN 1 ELSE 0 END)::bigint AS "Paid Users",
        -- MRR: місячний revenue від користувача
        COALESCE(sm.total_revenue,0)::bigint AS "MRR",
        -- ARPPU (user-level): для user-row — його MRR (буде агреговано на місяць пізніше)
        (CASE WHEN sm.paid = 1 THEN COALESCE(sm.total_revenue,0)::bigint ELSE 0 END) AS "ARPPU",
        -- NEW PAID USERS: 1 якщо цей місяць == first_payment_month (перший платіж користувача)
        (CASE WHEN up.first_payment_month IS NOT NULL AND up.first_payment_month = sm.payment_month THEN 1 ELSE 0 END)::bigint AS "New Paid Users",
        -- NEW MRR: якщо це перший платіж користувача — його місячний revenue
        (CASE WHEN up.first_payment_month IS NOT NULL AND up.first_payment_month = sm.payment_month THEN COALESCE(sm.total_revenue,0) ELSE 0 END)::bigint AS "New MRR",
        -- Churn Users: якщо платив у попередньому місяці, а зараз не платить -> 1
        (CASE WHEN COALESCE(sm.previous_paid, 0) = 1 AND sm.paid = 0 THEN 1 ELSE 0 END)::bigint AS "Churn Users",
        -- Churn MRR: від'ємна величина втрати MRR (має знак '-') -- беремо revenue попереднього місяця як втрату
        (CASE WHEN COALESCE(sm.previous_paid, 0) = 1 AND sm.paid = 0 THEN - (COALESCE(sm.previous_month_revenue,0)) ELSE 0 END)::bigint AS "Churn MRR",
        -- BACK FROM CHURN MRR: якщо платить зараз, в попередньому місяці не платив, і мав платіж раніше -> повернувся після churn
        (CASE WHEN sm.paid = 1 AND COALESCE(sm.previous_paid,0)=0 AND sm.last_paid_before_current IS NOT NULL THEN COALESCE(sm.total_revenue,0) ELSE 0 END)::bigint AS "Back from Churn MRR",
        -- Expansion MRR: якщо платив і збільшив платіж від попереднього місяця
        (CASE WHEN sm.paid = 1 AND COALESCE(sm.previous_paid,0)=1 AND sm.total_revenue > COALESCE(sm.previous_month_revenue,0)
              THEN (sm.total_revenue - COALESCE(sm.previous_month_revenue,0)) ELSE 0 END)::bigint AS "Expansion MRR",
        -- Contraction MRR: якщо платив, але зменшив платіж від попереднього місяця -> з від'ємним знаком
        (CASE WHEN sm.paid = 1 AND COALESCE(sm.previous_paid,0)=1 AND sm.total_revenue < COALESCE(sm.previous_month_revenue,0)
              THEN - (COALESCE(sm.previous_month_revenue,0) - sm.total_revenue) ELSE 0 END)::bigint AS "Contraction MRR",
        -- Customer LT (days): (last_payment_month - first_payment_month) + 1 днів, або 0 якщо немає даних
        (CASE
            WHEN up.first_payment_month IS NOT NULL AND up.last_payment_month IS NOT NULL
            THEN ( (up.last_payment_month - up.first_payment_month) + 1 )::bigint
            ELSE 0
         END)::bigint AS "Customer LT",
        -- Customer LTV: з профілю (ціле)
        COALESCE(up.ltv,0)::bigint AS "Customer LTV",
        -- Додаємо атрибути з таблиці games_paid_users
        gpu.language,
        gpu.age,
        gpu.has_older_device_model,
        gpu.game_name,
        -- Додаємо Age Group
        CASE
            WHEN gpu.age < 18 THEN '14-17'
            WHEN gpu.age >= 18 AND gpu.age < 25 THEN '18-24'
            WHEN gpu.age >= 25 AND gpu.age < 30 THEN '25-29'
            WHEN gpu.age >= 30 AND gpu.age < 35 THEN '30-34'
            WHEN gpu.age >= 35 AND gpu.age < 40 THEN '35-39'
            WHEN gpu.age >= 40 AND gpu.age < 45 THEN '40-45'
            ELSE 'UNKNOWN'
        END AS age_group
    FROM settlement_months sm
    LEFT JOIN user_profile up
        ON sm.user_id = up.user_id
    LEFT JOIN project.games_paid_users gpu
        ON sm.user_id = gpu.user_id
)
SELECT
    user_id AS "User ID",
    "Date",
    "Paid Users",
    "MRR",
    "ARPPU",
    "New Paid Users",
    "New MRR",
    "Churn Users",
    "Churn MRR",
    "Back from Churn MRR",
    "Expansion MRR",
    "Contraction MRR",
    "Customer LT",
    "Customer LTV",
    language AS "Language",
    age AS "Age",
    has_older_device_model AS "Old device model",
    game_name AS "Game",
    age_group AS "Age Group"
FROM metrics
ORDER BY "User ID", "Date";


