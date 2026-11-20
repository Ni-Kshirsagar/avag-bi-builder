"""Multi-connector framework for AVAG Natural Language BI Builder.

Supports Athena, Redshift, RDS (PostgreSQL/MySQL), Snowflake, and Databricks.
Each connector implements the BaseConnector interface and is configured via
YAML files in config/connections/.
"""
from llm_sql.connectors.base import BaseConnector
from llm_sql.connectors.registry import get_connector, list_connections, load_connections

__all__ = ['BaseConnector', 'get_connector', 'list_connections', 'load_connections']
