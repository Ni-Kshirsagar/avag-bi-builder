#!/usr/bin/env python3
"""Smoke test: loads the AVAG sample data (vehicle-models, sales, dealerships),
creates an in-memory SQLite DB, and runs basic SQL queries to verify the
local data path works.
Does NOT call AWS or Bedrock.
"""
import os
import sqlite3
import sys
import pandas as pd

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, 'data')

VEHICLES_CSV    = os.path.join(DATA_DIR, 'vehicle-models.csv')
SALES_CSV       = os.path.join(DATA_DIR, 'sales.csv')
DEALERSHIPS_CSV = os.path.join(DATA_DIR, 'dealerships.csv')


def load_vehicles() -> pd.DataFrame:
    print('Loading vehicle models from', VEHICLES_CSV)
    if not os.path.exists(VEHICLES_CSV):
        raise FileNotFoundError(f'File not found: {VEHICLES_CSV}')
    df = pd.read_csv(VEHICLES_CSV)
    print(f'  Loaded {len(df)} vehicle model records.')
    print('  Sample:', df.head(2).to_dict(orient='records'))
    return df


def load_sales() -> pd.DataFrame:
    print('Loading sales from', SALES_CSV)
    if not os.path.exists(SALES_CSV):
        raise FileNotFoundError(f'File not found: {SALES_CSV}')
    df = pd.read_csv(SALES_CSV, parse_dates=['sale_date'])
    df['net_price_eur'] = pd.to_numeric(df['net_price_eur'], errors='coerce')
    df['discount_pct']  = pd.to_numeric(df['discount_pct'],  errors='coerce')
    print(f'  Loaded {len(df)} sale records.')
    print('  Sample:', df.head(2).to_dict(orient='records'))
    return df


def load_dealerships() -> pd.DataFrame:
    print('Loading dealerships from', DEALERSHIPS_CSV)
    if not os.path.exists(DEALERSHIPS_CSV):
        raise FileNotFoundError(f'File not found: {DEALERSHIPS_CSV}')
    df = pd.read_csv(DEALERSHIPS_CSV)
    print(f'  Loaded {len(df)} dealership records.')
    print('  Sample:', df.head(2).to_dict(orient='records'))
    return df


def create_sqlite_and_query(
    vehicles_df: pd.DataFrame,
    sales_df: pd.DataFrame,
    dealerships_df: pd.DataFrame,
) -> dict:
    print('\nCreating in-memory SQLite DB and loading tables...')
    conn = sqlite3.connect(':memory:')
    vehicles_df.to_sql('vehicle_models', conn, index=False, if_exists='replace')
    sales_df.to_sql('sales',             conn, index=False, if_exists='replace')
    dealerships_df.to_sql('dealerships', conn, index=False, if_exists='replace')
    cur = conn.cursor()

    queries = [
        ('Total sales records',
         'SELECT COUNT(*) FROM sales;'),
        ('Total vehicle models',
         'SELECT COUNT(*) FROM vehicle_models;'),
        ('Average net price (EUR)',
         'SELECT ROUND(AVG(net_price_eur), 2) FROM sales;'),
        ('Top brand by sales volume',
         '''SELECT vm.brand, COUNT(*) AS sales_count
            FROM sales s
            JOIN vehicle_models vm ON s.model_id = vm.model_id
            GROUP BY vm.brand
            ORDER BY sales_count DESC
            LIMIT 1;'''),
        ('Dealerships per region',
         '''SELECT region, COUNT(*) AS count
            FROM dealerships
            GROUP BY region
            ORDER BY count DESC;'''),
        ('Sales by sales channel',
         '''SELECT sales_channel, COUNT(*) AS cnt
            FROM sales
            GROUP BY sales_channel
            ORDER BY cnt DESC;'''),
    ]

    results = {}
    for name, sql in queries:
        cur.execute(sql)
        rows = cur.fetchall()
        results[name] = rows
        print(f'  {name}: {rows}')

    conn.close()
    return results


def main() -> int:
    print('=' * 60)
    print('Smoke Test — Natural Language BI Builder (AVAG)')
    print('=' * 60)

    try:
        vehicles_df = load_vehicles()
    except Exception as exc:
        print(f'FAIL: Vehicle models load — {exc}')
        return 2

    try:
        sales_df = load_sales()
    except Exception as exc:
        print(f'FAIL: Sales load — {exc}')
        return 3

    try:
        dealerships_df = load_dealerships()
    except Exception as exc:
        print(f'FAIL: Dealerships load — {exc}')
        return 4

    try:
        create_sqlite_and_query(vehicles_df, sales_df, dealerships_df)
    except Exception as exc:
        print(f'FAIL: SQLite smoke queries — {exc}')
        return 5

    print('\nSmoke test completed successfully.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
