#include "JsonListModel.h"
#include <QVariantMap>

JsonListModel::JsonListModel(QString keyField, QObject *parent)
    : QAbstractListModel(parent), m_keyField(std::move(keyField)) {}

int JsonListModel::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : m_items.size(); }

QVariant JsonListModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() >= m_items.size()) return {};
    const int slot = role - Qt::UserRole;
    if (slot < 0 || slot >= m_roleKeys.size()) return {};
    return m_items[index.row()].toMap().value(m_roleKeys[slot]);
}

QHash<int, QByteArray> JsonListModel::roleNames() const { return m_roles; }

void JsonListModel::setItems(const QVariantList &items) {
    // Roles come from the first item; a view needs them before it asks for rows.
    QList<QString> keys;
    if (!items.isEmpty()) keys = items.first().toMap().keys();
    const bool sameShape = keys == m_roleKeys || items.isEmpty();

    bool sameRows = sameShape && items.size() == m_items.size();
    for (int i = 0; sameRows && i < items.size(); ++i)
        sameRows = items[i].toMap().value(m_keyField) == m_items[i].toMap().value(m_keyField);

    if (sameRows) {
        for (int i = 0; i < items.size(); ++i) {
            if (items[i] == m_items[i]) continue;
            m_items[i] = items[i];
            emit dataChanged(index(i), index(i));
        }
        return;
    }

    beginResetModel();
    m_items = items;
    if (!items.isEmpty()) {
        m_roleKeys = keys;
        m_roles.clear();
        for (int i = 0; i < keys.size(); ++i) m_roles.insert(Qt::UserRole + i, keys[i].toUtf8());
    }
    endResetModel();
}
