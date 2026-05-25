"""p8_push_devices_outbox

Adds device push-token storage and the push outbox (transactional-outbox) table
backing JPush delivery.

Revision ID: d4e5f6a7b8c9
Revises: 091db215b2c4
Create Date: 2026-05-25 16:10:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'd4e5f6a7b8c9'
down_revision: str | None = '091db215b2c4'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'device_tokens',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('user_id', sa.Uuid(), nullable=False),
        sa.Column('registration_id', sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column('platform', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_device_tokens_user_id'), 'device_tokens', ['user_id'], unique=False
    )
    op.create_index(
        op.f('ix_device_tokens_registration_id'),
        'device_tokens',
        ['registration_id'],
        unique=True,
    )

    op.create_table(
        'push_outbox',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('notification_id', sa.Uuid(), nullable=False),
        sa.Column('status', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('attempts', sa.Integer(), nullable=False),
        sa.Column('last_error', sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('sent_at', sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(['notification_id'], ['notifications.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_push_outbox_notification_id'),
        'push_outbox',
        ['notification_id'],
        unique=False,
    )
    op.create_index(
        'ix_push_outbox_status_created',
        'push_outbox',
        ['status', 'created_at'],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index('ix_push_outbox_status_created', table_name='push_outbox')
    op.drop_index(op.f('ix_push_outbox_notification_id'), table_name='push_outbox')
    op.drop_table('push_outbox')
    op.drop_index(op.f('ix_device_tokens_registration_id'), table_name='device_tokens')
    op.drop_index(op.f('ix_device_tokens_user_id'), table_name='device_tokens')
    op.drop_table('device_tokens')
