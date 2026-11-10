#include "Controller.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <cmath>
#include <QSettings>
#include <QQuickWindow>
#include <algorithm>
extern "C" {
#include "wirebench_bridge.h"
}

namespace {
QByteArray toJson(const QVariantMap &map) { return QJsonDocument::fromVariant(map).toJson(QJsonDocument::Compact); }
}

Controller::Controller(QObject *parent) : QObject(parent), m_session(wirebench_create()) {
    m_blurEnabled = QSettings().value("blurEnabled", true).toBool();
    m_blurDepth = QSettings().value("blurDepth", 0.55).toDouble();
    // Overrides for checking a look without touching what is saved: WIREBENCH_BLUR=0|1, WIREBENCH_BLUR_DEPTH=0.1..1.
    if (qEnvironmentVariableIsSet("WIREBENCH_BLUR")) m_blurEnabled = qEnvironmentVariableIntValue("WIREBENCH_BLUR") != 0;
    if (qEnvironmentVariableIsSet("WIREBENCH_BLUR_DEPTH")) m_blurDepth = qEnvironmentVariable("WIREBENCH_BLUR_DEPTH").toDouble();
    // Roomier pin rows than the SwiftUI card's 16, unless the user chose otherwise.
    wirebench_command(m_session, toJson({{"cmd", "setSetting"}, {"key", "pinPitch"},
                                      {"value", QSettings().value("pinPitch", 20.0).toDouble()}}).constData());
    // A macro call needs no room for the SwiftUI card's open-macro button: its card is as tall as its pins.
    wirebench_command(m_session, toJson({{"cmd", "setSetting"}, {"key", "macroCallerSpace"}, {"value", 0}}).constData());
    connect(&m_timer, &QTimer::timeout, this, &Controller::onTimer);
    m_timer.setInterval(12);
    m_timer.start();
    m_clock.start();
    refresh();
}

Controller::~Controller() { wirebench_destroy(m_session); }

QStringList Controller::pages() const {
    QStringList out;
    for (const QVariant &page : m_scene.value("pages").toList()) out << page.toString();
    return out;
}

void Controller::refresh() {
    char *raw = wirebench_scene(m_session);
    const QJsonDocument document = QJsonDocument::fromJson(QByteArray(raw));
    wirebench_free(raw);
    const QVariantMap oldSettings = settings(), oldHardware = hardware();
    const QVariantList oldPages = m_scene.value("pages").toList(), oldPagesInfo = pagesInfo();
    const QString oldTitle = title(), oldFile = file(), oldPage = page();
    const bool oldEdited = edited();
    const QVariantMap oldInspector = m_inspector;
    m_scene = document.toVariant().toMap();

    // A wire has no id of its own; its ends name it.
    QVariantList wires = m_scene.value("wires").toList();
    for (QVariant &wire : wires) {
        QVariantMap map = wire.toMap();
        map["key"] = QString("%1.%2>%3.%4%5").arg(map["outModule"].toInt()).arg(map["outPin"].toInt())
                         .arg(map["inModule"].toInt()).arg(map["inPin"].toInt()).arg(map["inParam"].toBool() ? "p" : "");
        wire = map;
    }
    m_modules.setItems(m_scene.value("modules").toList());
    m_wires.setItems(wires);
    m_graphics.setItems(m_scene.value("graphics").toList());

    // The inspector follows a single selected block.
    m_inspector.clear();
    const QVariantList selected = selectedIds();
    if (selected.size() == 1) {
        const QByteArray request = toJson({{"cmd", "inspect"}, {"id", selected.first()}});
        char *answer = wirebench_command(m_session, request.constData());
        m_inspector = QJsonDocument::fromJson(QByteArray(answer)).toVariant().toMap().value("inspector").toMap();
        wirebench_free(answer);
    }
    if (title() != oldTitle || file() != oldFile || page() != oldPage || edited() != oldEdited
        || m_scene.value("pages").toList() != oldPages || pagesInfo() != oldPagesInfo) emit projectChanged();
    if (settings() != oldSettings) emit settingsChanged();
    if (hardware() != oldHardware) emit hardwareChanged();
    if (m_inspector != oldInspector) emit inspectorChanged();
    emit sceneChanged();
}

QVariantMap Controller::command(const QVariantMap &arguments) {
    char *raw = wirebench_command(m_session, toJson(arguments).constData());
    const QVariantMap reply = QJsonDocument::fromJson(QByteArray(raw)).toVariant().toMap();
    wirebench_free(raw);
    refresh();
    return reply;
}

void Controller::onTimer() {
    const double elapsed = m_clock.restart() / 1.0;   // milliseconds
    wirebench_pump();
    if (wirebench_tick(m_session, elapsed)) refresh();
    const qulonglong ticks = wirebench_tick_count(m_session);
    if (ticks != m_tick) { m_tick = ticks; emit tickChanged(); }
}

void Controller::setPinPitch(double pitch) {
    QSettings().setValue("pinPitch", pitch);
    command({{"cmd", "setSetting"}, {"key", "pinPitch"}, {"value", pitch}});
}

QVariantMap Controller::pinAt(double x, double y, const QString &side) const {
    const double reach = 11;
    const double pitch = m_scene.value("settings").toMap().value("pinPitch", 16.0).toDouble();
    const double first = m_scene.value("settings").toMap().value("firstPin", 33.0).toDouble();
    const double inset = 12;   // the centre of a pin dot sits this far inside the card edge (BlockCard.dotInset + 5)
    for (const QVariant &entry : m_modules.items()) {
        const QVariantMap module = entry.toMap();
        const double mx = module["x"].toDouble(), my = module["y"].toDouble();
        const QVariantList pins = module[side == "in" ? "inPins" : "outPins"].toList();
        const double px = side == "in" ? mx + inset : mx + module["w"].toDouble() - inset;
        for (int i = 0; i < pins.size(); ++i) {
            const double py = my + first + pitch * i;
            if (std::abs(x - px) <= reach && std::abs(y - py) <= reach)
                return {{"module", module["id"]}, {"pin", i}, {"side", side}, {"x", px}, {"y", py}};
        }
        // The parameters are pins too: rows under the inputs, wired the same way.
        if (side == "in") {
            const int inputs = pins.size();
            const QVariantList params = module["paramPins"].toList();
            for (int i = 0; i < params.size(); ++i) {
                const double py = my + first + pitch * (inputs + i);
                if (std::abs(x - px) <= reach && std::abs(y - py) <= reach)
                    return {{"module", module["id"]}, {"pin", i}, {"side", side}, {"param", true}, {"x", px}, {"y", py}};
            }
        }
    }
    return {};
}

QVariantList Controller::selectedIds() const {
    QVariantList ids;
    for (const QVariant &entry : m_modules.items()) {
        const QVariantMap module = entry.toMap();
        if (module["selected"].toBool()) ids << module["id"];
    }
    return ids;
}

QVariantList Controller::selectedGraphics() const {
    QVariantList indices;
    for (const QVariant &entry : m_graphics.items()) {
        const QVariantMap graphic = entry.toMap();
        if (graphic["selected"].toBool()) indices << graphic["index"];
    }
    return indices;
}

QVariantMap Controller::graphic(int index) const {
    for (const QVariant &entry : m_graphics.items())
        if (entry.toMap()["index"].toInt() == index) return entry.toMap();
    return {};
}

QVariantMap Controller::contentBounds() const {
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    auto grow = [&](double x, double y, double w, double h) {
        x0 = std::min(x0, x); y0 = std::min(y0, y); x1 = std::max(x1, x + w); y1 = std::max(y1, y + h);
    };
    for (const QVariant &entry : m_modules.items()) {
        const QVariantMap m = entry.toMap();
        grow(m["x"].toDouble(), m["y"].toDouble(), m["w"].toDouble(), m["h"].toDouble());
    }
    for (const QVariant &entry : m_graphics.items()) {
        const QVariantMap g = entry.toMap();
        // A text object has no stored size; allow room for a line of it.
        const bool text = g["kind"].toString() == "text";
        grow(g["x"].toDouble(), g["y"].toDouble(), text ? 240 : g["w"].toDouble(), text ? 20 : g["h"].toDouble());
    }
    if (x0 > x1) return {};
    return {{"x", x0}, {"y", y0}, {"w", x1 - x0}, {"h", y1 - y0}};
}

QString Controller::suggestedName(const QString &extension) const {
    QString base = file().isEmpty() ? title() : file();
    if (base.isEmpty()) base = "project";
    const int dot = base.lastIndexOf('.');
    if (dot > base.lastIndexOf('/')) base.truncate(dot);
    return base + extension;
}

QVariantMap Controller::itemsIn(double x, double y, double w, double h) const {
    auto touches = [&](double ox, double oy, double ow, double oh) {
        return ox < x + w && x < ox + ow && oy < y + h && y < oy + oh;
    };
    QVariantList ids, graphics;
    for (const QVariant &entry : m_modules.items()) {
        const QVariantMap m = entry.toMap();
        if (touches(m["x"].toDouble(), m["y"].toDouble(), m["w"].toDouble(), m["h"].toDouble())) ids << m["id"];
    }
    for (const QVariant &entry : m_graphics.items()) {
        const QVariantMap g = entry.toMap();
        const bool text = g["kind"].toString() == "text";
        if (touches(g["x"].toDouble(), g["y"].toDouble(), text ? 240 : g["w"].toDouble(), text ? 20 : g["h"].toDouble())) graphics << g["index"];
    }
    return {{"ids", ids}, {"graphics", graphics}};
}

void Controller::setBlurEnabled(bool on) {
    if (on == m_blurEnabled) return;
    m_blurEnabled = on;
    QSettings().setValue("blurEnabled", on);
    emit blurChanged();
}

void Controller::setBlurDepth(double depth) {
    depth = std::clamp(depth, 0.0, 1.0);
    if (depth == m_blurDepth) return;
    m_blurDepth = depth;
    QSettings().setValue("blurDepth", depth);
    emit blurChanged();
}

void Controller::saveWindow(QObject *window, const QString &path) const {
    if (auto *w = qobject_cast<QQuickWindow *>(window)) w->grabWindow().save(path);
}

QVariantMap Controller::wireAt(double x, double y, double tolerance) const {
    double best = tolerance;
    QVariantMap found;
    for (const QVariant &entry : m_wires.items()) {
        const QVariantMap wire = entry.toMap();
        const QVariantList points = wire["points"].toList();
        for (int i = 1; i < points.size(); ++i) {
            const QVariantList a = points[i - 1].toList(), b = points[i].toList();
            if (a.size() < 2 || b.size() < 2) continue;
            const double ax = a[0].toDouble(), ay = a[1].toDouble(), bx = b[0].toDouble(), by = b[1].toDouble();
            const double dx = bx - ax, dy = by - ay, length2 = dx * dx + dy * dy;
            double t = length2 > 0 ? ((x - ax) * dx + (y - ay) * dy) / length2 : 0;
            t = std::clamp(t, 0.0, 1.0);
            const double distance = std::hypot(x - (ax + t * dx), y - (ay + t * dy));
            if (distance < best) { best = distance; found = wire; }
        }
    }
    return found;
}
