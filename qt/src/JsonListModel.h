#pragma once
#include <QAbstractListModel>
#include <QVariantList>

// A list of JSON objects as a model: one role per key of the first object. Replacing the list with one that has
// the same keys in the same order updates the rows in place, so views keep their delegates (and any drag state) while
// a simulation tick changes the values.
class JsonListModel : public QAbstractListModel {
    Q_OBJECT
public:
    explicit JsonListModel(QString keyField, QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setItems(const QVariantList &items);
    const QVariantList &items() const { return m_items; }

private:
    QString m_keyField;
    QVariantList m_items;
    QHash<int, QByteArray> m_roles;
    QList<QString> m_roleKeys;
};
