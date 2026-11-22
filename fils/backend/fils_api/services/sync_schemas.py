"""Strict per-entity payload validation for sync envelopes.

Unknown fields are rejected (extra="forbid") so a client/server mismatch surfaces as an
explicit `rejected` result rather than silent data loss.
"""
from __future__ import annotations

import re
import uuid
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, field_validator

MAX_MINOR = 10**15  # generous upper bound; guards against overflow/garbage

Currency = str


def _currency(v: str) -> str:
    if not re.fullmatch(r"[A-Z]{3}", v or ""):
        raise ValueError("currency must be a 3-letter uppercase ISO code")
    return v


class _P(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: uuid.UUID


MinorInt = Annotated[int, Field(ge=-MAX_MINOR, le=MAX_MINOR)]
NonNegInt = Annotated[int, Field(ge=0, le=MAX_MINOR)]

SYSTEM_CATEGORY_SLUG = re.compile(r"^[a-z][a-z0-9_]{1,39}$")


def _cat_id(v):
    """Category ids are UUIDs (user categories) or built-in system slugs such as 'transfers'."""
    if v is None:
        return v
    s = str(v)
    try:
        return str(uuid.UUID(s))
    except ValueError:
        if SYSTEM_CATEGORY_SLUG.fullmatch(s):
            return s
        raise ValueError("category id must be a UUID or a system category slug")


CategoryId = Annotated[str, BeforeValidator(_cat_id)]


class AccountP(_P):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["bank", "card", "cash", "wallet", "loan", "savings"]
    institution_id: str | None = Field(default=None, max_length=40)
    currency: str
    mask_last4: str | None = Field(default=None, pattern=r"^\d{2,4}$")
    is_liability: bool = False
    credit_limit_minor: NonNegInt | None = None
    opening_balance_minor: MinorInt
    opening_balance_date: date
    reported_balance_minor: MinorInt | None = None
    reported_available_minor: MinorInt | None = None
    reported_balance_at: datetime | None = None
    archived: bool = False
    color: str | None = Field(default=None, max_length=16)
    sort_order: int = 0
    is_default: bool = False
    include_in_net_worth: bool = True

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))


class SplitP(BaseModel):
    model_config = ConfigDict(extra="forbid")
    category_id: CategoryId
    amount_minor: NonNegInt
    note: str | None = Field(default=None, max_length=200)


class TransactionP(_P):
    account_id: uuid.UUID
    kind: Literal["expense", "income", "transfer", "refund", "adjust_up", "adjust_down"]
    status: Literal["posted", "pending", "declined", "void"]
    amount_minor: NonNegInt
    currency: str
    counter_account_id: uuid.UUID | None = None
    counter_amount_minor: NonNegInt | None = None
    original_amount_minor: NonNegInt | None = None
    original_currency: str | None = None
    fx_rate: str | None = Field(default=None, max_length=32)
    fx_source: str | None = Field(default=None, max_length=40)
    merchant: str | None = Field(default=None, max_length=120)
    merchant_raw: str | None = Field(default=None, max_length=200)
    category_id: CategoryId | None = None
    note: str | None = Field(default=None, max_length=500)
    occurred_at: datetime
    received_at: datetime | None = None
    source: Literal[
        "manual", "voice", "sms", "notification", "shortcut", "wallet", "csv", "pdf", "image", "paste", "share", "recurring"
    ]
    source_event_id: str | None = Field(default=None, max_length=128)
    refund_of_id: uuid.UUID | None = None
    transfer_group_id: uuid.UUID | None = None
    parser_id: str | None = Field(default=None, max_length=60)
    parser_version: str | None = Field(default=None, max_length=20)
    confidence: float | None = Field(default=None, ge=0, le=1)
    needs_review: bool = False
    splits: list[SplitP] = Field(default_factory=list, max_length=50)

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))

    @field_validator("original_currency")
    @classmethod
    def _oc(cls, v):
        return None if v is None else _currency(v)

    @field_validator("fx_rate")
    @classmethod
    def _fx(cls, v):
        if v is None:
            return v
        try:
            d = Decimal(v)
        except InvalidOperation as e:
            raise ValueError("fx_rate must be a decimal string") from e
        if d <= 0:
            raise ValueError("fx_rate must be positive")
        return v

    def model_post_init(self, _ctx: Any) -> None:
        if self.kind == "transfer" and self.counter_account_id is None:
            raise ValueError("transfer requires counter_account_id")
        if self.splits and sum(s.amount_minor for s in self.splits) != self.amount_minor:
            raise ValueError("splits must sum to amount_minor")


class CategoryP(_P):
    name_en: str = Field(min_length=1, max_length=60)
    name_ar: str = Field(min_length=1, max_length=60)
    icon: str = Field(max_length=16)
    color: str = Field(max_length=16)
    kind: Literal["expense", "income"]
    parent_id: CategoryId | None = None
    is_system: bool = False
    archived: bool = False


class BudgetP(_P):
    category_id: CategoryId | None = None
    amount_minor: NonNegInt
    currency: str
    period: Literal["cycle", "monthly", "weekly"]
    rollover: bool = False
    alert_thresholds: list[int] = Field(default_factory=lambda: [80, 100], max_length=5)
    start_date: date

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))


class ContributionP(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: uuid.UUID
    amount_minor: MinorInt
    date: date
    note: str | None = Field(default=None, max_length=200)


class GoalP(_P):
    name: str = Field(min_length=1, max_length=80)
    emoji: str | None = Field(default=None, max_length=16)
    target_minor: NonNegInt
    currency: str
    target_date: date | None = None
    account_id: uuid.UUID | None = None
    planned_monthly_minor: NonNegInt | None = None
    contributions: list[ContributionP] = Field(default_factory=list, max_length=2000)
    archived: bool = False

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))


class RecurringP(_P):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["subscription", "rent", "installment", "bill", "salary", "other"]
    amount_minor: NonNegInt
    currency: str
    account_id: uuid.UUID | None = None
    category_id: CategoryId | None = None
    cadence: Literal["weekly", "monthly", "yearly"]
    interval: int = Field(default=1, ge=1, le=24)
    anchor_date: date
    next_due_date: date
    total_occurrences: int | None = Field(default=None, ge=1, le=1200)
    completed_occurrences: int = Field(default=0, ge=0)
    merchant_pattern: str | None = Field(default=None, max_length=120)
    status: Literal["suggested", "active", "paused", "ended"]
    reminder_days_before: int = Field(default=2, ge=0, le=30)

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))


class MerchantAliasP(_P):
    pattern: str = Field(min_length=1, max_length=120)
    merchant: str = Field(min_length=1, max_length=120)
    category_id: CategoryId | None = None


class AssetP(_P):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["gold", "property", "vehicle", "investment", "deposit", "cash", "other", "loan"]
    is_liability: bool = False
    value_minor: NonNegInt
    currency: str
    valuation_date: date
    valuation_source: Literal["manual"] = "manual"
    linked_account_id: uuid.UUID | None = None
    note: str | None = Field(default=None, max_length=300)

    v_currency = field_validator("currency")(lambda cls, v: _currency(v))


SYNCED_SETTING_KEYS = {"salary_day", "cycle_start_day", "base_currency", "locale", "week_start", "budget_cycle"}


class SettingP(_P):
    key: str = Field(max_length=40)
    value: Any

    @field_validator("key")
    @classmethod
    def _k(cls, v):
        if v not in SYNCED_SETTING_KEYS:
            raise ValueError("setting key is not syncable")
        return v


ENTITY_MODELS: dict[str, type[_P]] = {
    "account": AccountP,
    "transaction": TransactionP,
    "category": CategoryP,
    "budget": BudgetP,
    "goal": GoalP,
    "recurring": RecurringP,
    "merchant_alias": MerchantAliasP,
    "asset": AssetP,
    "setting": SettingP,
}

# Processing order so referenced records in the same batch are applied first.
ENTITY_ORDER = ["category", "account", "merchant_alias", "asset", "setting", "goal", "budget", "recurring", "transaction"]

# (field, referenced entity) pairs that must resolve within the same scope.
REFERENCES: dict[str, list[tuple[str, str]]] = {
    "account": [],
    "transaction": [
        ("account_id", "account"),
        ("counter_account_id", "account"),
        ("category_id", "category"),
        ("refund_of_id", "transaction"),
    ],
    "category": [("parent_id", "category")],
    "budget": [("category_id", "category")],
    "goal": [("account_id", "account")],
    "recurring": [("account_id", "account"), ("category_id", "category")],
    "merchant_alias": [("category_id", "category")],
    "asset": [("linked_account_id", "account")],
    "setting": [],
}
