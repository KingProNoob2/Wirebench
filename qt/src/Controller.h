#pragma once
#include <QObject>
#include <QUrl>
#include <QTimer>
#include <QVariantMap>
#include <QElapsedTimer>
#include "JsonListModel.h"

struct WirebenchSession;

// The Swift model behind QML: commands go in as JSON, the scene comes back as models and properties. All calls are
// on the GUI thread, which is the thread the bridge requires.
class Controller : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject *modules READ modules CONSTANT)
    Q_PROPERTY(QObject *wires READ wires CONSTANT)
    Q_PROPERTY(QObject *graphics READ graphics CONSTANT)
    Q_PROPERTY(QString title READ title NOTIFY projectChanged)
    Q_PROPERTY(QString file READ file NOTIFY projectChanged)
    Q_PROPERTY(QString page READ page NOTIFY projectChanged)
    Q_PROPERTY(QStringList pages READ pages NOTIFY projectChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY sceneChanged)
    Q_PROPERTY(bool hasProject READ hasProject NOTIFY sceneChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY sceneChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY sceneChanged)
    Q_PROPERTY(bool edited READ edited NOTIFY projectChanged)
    Q_PROPERTY(qulonglong tick READ tick NOTIFY tickChanged)
    Q_PROPERTY(QVariantMap inspector READ inspector NOTIFY inspectorChanged)
    Q_PROPERTY(QVariantMap hardware READ hardware NOTIFY hardwareChanged)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    // Frosted-glass panels: whether the sheet is blurred behind them, and how strongly: a slider position 0 to 1, exponential in the blur radius (AppTheme.blurSigma). Remembered between runs.
    Q_PROPERTY(bool blurEnabled READ blurEnabled WRITE setBlurEnabled NOTIFY blurChanged)
    Q_PROPERTY(double blurDepth READ blurDepth WRITE setBlurDepth NOTIFY blurChanged)
    Q_PROPERTY(QVariantList pagesInfo READ pagesInfo NOTIFY projectChanged)
    // What the model is waiting on the frontend for: a question to ask (`unsaved`), a file dialog to show (`open`, `saveAs`), or to quit.
    Q_PROPERTY(QString question READ question NOTIFY sceneChanged)
    Q_PROPERTY(QString panel READ panel NOTIFY sceneChanged)
    Q_PROPERTY(bool quitRequested READ quitRequested NOTIFY sceneChanged)
    Q_PROPERTY(QString alert READ alert NOTIFY sceneChanged)
public:
    explicit Controller(QObject *parent = nullptr);
    ~Controller() override;

    QObject *modules() { return &m_modules; }
    QObject *wires() { return &m_wires; }
    QObject *graphics() { return &m_graphics; }
    QString title() const { return m_scene.value("title").toString(); }
    QString file() const { return m_scene.value("file").toString(); }
    QString page() const { return m_scene.value("page").toString(); }
    QStringList pages() const;
    bool playing() const { return m_scene.value("playing").toBool(); }
    bool hasProject() const { return m_scene.value("hasProject").toBool(); }
    bool canUndo() const { return m_scene.value("canUndo").toBool(); }
    bool canRedo() const { return m_scene.value("canRedo").toBool(); }
    bool edited() const { return m_scene.value("edited").toBool(); }
    qulonglong tick() const { return m_tick; }
    QVariantMap inspector() const { return m_inspector; }
    QVariantMap hardware() const { return m_scene.value("hardware").toMap(); }
    QVariantMap settings() const { return m_scene.value("settings").toMap(); }
    bool blurEnabled() const { return m_blurEnabled; }
    double blurDepth() const { return m_blurDepth; }
    void setBlurEnabled(bool on);
    void setBlurDepth(double depth);
    QVariantList pagesInfo() const { return m_scene.value("pagesInfo").toList(); }
    QString question() const { return m_scene.value("question").toString(); }
    QString panel() const { return m_scene.value("panel").toString(); }
    bool quitRequested() const { return m_scene.value("quit").toBool(); }
    QString alert() const { return m_scene.value("alert").toString(); }

    // Runs a command object (see the bridge header) and returns its reply.
    Q_INVOKABLE QVariantMap command(const QVariantMap &arguments);
    // The pin under a canvas point: {module, pin, side}, or an empty map. `side` is "in" or "out".
    // How far apart pin rows are drawn (remembered between runs); wires and pin positions follow.
    Q_INVOKABLE void setPinPitch(double pitch);
    // Saves the window as a picture (for checking the look; used by the WIREBENCH_SHOT_* hooks).
    Q_INVOKABLE void saveWindow(QObject *window, const QString &path) const;
    // A file chosen in a dialog, as a path.
    Q_INVOKABLE QString localPath(const QUrl &url) const { return url.toLocalFile(); }
    // A name to offer when saving: the project's own, with `extension`.
    Q_INVOKABLE QString suggestedName(const QString &extension) const;
    // The wire nearest a point of the sheet, within `tolerance` units: {key, outModule, outPin, inModule, inPin}, or empty.
    Q_INVOKABLE QVariantMap wireAt(double x, double y, double tolerance) const;
    // The ids of the selected blocks.
    Q_INVOKABLE QVariantList selectedIds() const;
    // The indices of the selected shapes and text objects.
    Q_INVOKABLE QVariantList selectedGraphics() const;
    // The blocks and graphics a rectangle of the sheet touches: {ids: [...], graphics: [...]}.
    Q_INVOKABLE QVariantMap itemsIn(double x, double y, double w, double h) const;
    // The box around every block and graphic on the page, or an empty map for an empty page.
    Q_INVOKABLE QVariantMap contentBounds() const;
    // One shape or text object by its index, or an empty map.
    Q_INVOKABLE QVariantMap graphic(int index) const;
    Q_INVOKABLE QVariantMap pinAt(double x, double y, const QString &side) const;

signals:
    // Something visible changed: the play state, the tick count, undo and redo, an alert. Fires on every simulation step.
    void sceneChanged();
    // The cycle count moved. Separate from `sceneChanged`, which only fires when a value did: a project that settles still runs.
    void tickChanged();
    // The rest change rarely, and have their own signals so a step does not make every card re-evaluate its bindings.
    void projectChanged();
    void settingsChanged();
    void hardwareChanged();
    void inspectorChanged();
    void blurChanged();

private:
    void refresh();
    void onTimer();

    WirebenchSession *m_session = nullptr;
    JsonListModel m_modules{"id"};
    JsonListModel m_wires{"key"};
    JsonListModel m_graphics{"index"};
    bool m_blurEnabled = true;
    double m_blurDepth = 0.55;
    QVariantMap m_scene;
    QVariantMap m_inspector;
    QTimer m_timer;
    QElapsedTimer m_clock;
    qulonglong m_tick = 0;
};
