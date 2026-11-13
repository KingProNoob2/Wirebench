#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>
#include <QFont>
#include <QFontDatabase>
#include <QStyleHints>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include "Controller.h"

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("Wirebench");
    QQuickStyle::setStyle("Basic");
    QFont font;
    // The first of these that is installed (naming one that is not makes Qt search for it on every start).
    const QStringList installed = QFontDatabase::families();
    for (const QString &family : {"Inter", "SF Pro Text", ".AppleSystemUIFont", "Segoe UI", "Noto Sans", "Nimbus Sans", "DejaVu Sans"}) {
        if (installed.contains(family)) { font.setFamily(family); break; }
    }
    font.setPixelSize(12);
    app.setFont(font);
    // WIREBENCH_LIGHT=1 forces light mode, for checking the theme without a desktop that sets it.

    Controller controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("controller", &controller);
    // WIREBENCH_LIGHT=1 forces light mode, for checking the theme without a desktop that sets it.
    // WIREBENCH_CONFIG=1 opens the configuration of the preselected block at start, for screenshots.
    engine.rootContext()->setContextProperty("startConfig", qEnvironmentVariableIntValue("WIREBENCH_CONFIG") != 0);
    // WIREBENCH_DIALOG=build|hardware opens that dialog at start, for screenshots.
    engine.rootContext()->setContextProperty("startDialog", QString::fromLocal8Bit(qgetenv("WIREBENCH_DIALOG")));
    // WIREBENCH_ZOOM=1.8 zooms in on the content at start, for screenshots.
    engine.rootContext()->setContextProperty("startZoom", qEnvironmentVariable("WIREBENCH_ZOOM", "0").toDouble());
    // Whether the scene graph draws on the GPU; blur and the glass panels need it.
    engine.rootContext()->setContextProperty("gpuRendering", !(
        QQuickWindow::sceneGraphBackend() == QLatin1String("software")
        || qgetenv("QT_QUICK_BACKEND") == "software" || qgetenv("QMLSCENE_DEVICE") == "softwarecontext"));
    // WIREBENCH_BENCH=1 pans the sheet back and forth continuously, to measure frame times (QSG_RENDER_TIMING=1).
    engine.rootContext()->setContextProperty("benchPan", qEnvironmentVariableIntValue("WIREBENCH_BENCH") != 0);
    // WIREBENCH_PAN=dx,dy moves the sheet by that much after the zoom, to compare frames a fraction of a pixel apart.
    engine.rootContext()->setContextProperty("startPan", QString::fromLocal8Bit(qgetenv("WIREBENCH_PAN")));
    engine.rootContext()->setContextProperty("shotAfterToggle", qEnvironmentVariableIntValue("WIREBENCH_SHOT_AFTER_TOGGLE_MS"));
    engine.rootContext()->setContextProperty("shotPath", QString::fromLocal8Bit(qgetenv("WIREBENCH_SHOT_PATH")));
    engine.rootContext()->setContextProperty("startHidden", qEnvironmentVariableIntValue("WIREBENCH_START_HIDDEN") != 0);
    engine.rootContext()->setContextProperty("selectAt", QString::fromLocal8Bit(qgetenv("WIREBENCH_SELECT_AT")));
    engine.rootContext()->setContextProperty("pageAt", QString::fromLocal8Bit(qgetenv("WIREBENCH_PAGE_AT")));
    // WIREBENCH_SIZE=WxH sets the window's size, to check how the layout copes with a small one.
    {
        const QStringList size = QString::fromLocal8Bit(qgetenv("WIREBENCH_SIZE")).split('x');
        engine.rootContext()->setContextProperty("startW", size.size() == 2 ? size[0].toInt() : 0);
        engine.rootContext()->setContextProperty("startH", size.size() == 2 ? size[1].toInt() : 0);
    }
    engine.rootContext()->setContextProperty("toggleMs", qEnvironmentVariableIntValue("WIREBENCH_TOGGLE_MS"));
    engine.rootContext()->setContextProperty("forceLight", qEnvironmentVariableIntValue("WIREBENCH_LIGHT") != 0);
    // `wirebench-qt project.wbp` opens a project on start.
    if (argc > 1) controller.command({{"cmd", "open"}, {"path", QString::fromLocal8Bit(argv[1])}});
    // WIREBENCH_PRE='[{"cmd":"select","ids":[4]}]' runs commands first, for screenshots of a particular state.
    for (const QJsonValue &step : QJsonDocument::fromJson(qgetenv("WIREBENCH_PRE")).array())
        controller.command(step.toObject().toVariantMap());
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Wirebench", "Main");
    // WIREBENCH_SCREENSHOT=out.png saves the first frame after a moment and quits, for checking the UI without a display.
    if (const QByteArray shot = qgetenv("WIREBENCH_SCREENSHOT"); !shot.isEmpty() && !engine.rootObjects().isEmpty()) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        const int play = qEnvironmentVariableIntValue("WIREBENCH_PLAY_MS");
        if (play > 0) controller.command({{"cmd", "play"}});
        const int at = qEnvironmentVariableIsSet("WIREBENCH_SHOT_MS") ? qEnvironmentVariableIntValue("WIREBENCH_SHOT_MS") : 1500 + play;
        QTimer::singleShot(at, &app, [&app, window, shot] { window->grabWindow().save(QString::fromLocal8Bit(shot)); window->setProperty("allowClose", true); app.quit(); });
    }
    // WIREBENCH_GRABS=dir saves a run of consecutive frames while the benchmark pans, to measure flicker between them.
    if (const QByteArray dir = qgetenv("WIREBENCH_GRABS"); !dir.isEmpty() && !engine.rootObjects().isEmpty()) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        auto *timer = new QTimer(&app);
        auto *count = new int(0);
        QObject::connect(timer, &QTimer::timeout, &app, [window, dir, timer, count, &app] {
            // Frame k has the sheet moved by exactly k * 0.37 px, so the sequence is smooth and any jitter is the renderer's.
            const double base = window->property("panX").toDouble() - (*count > 0 ? 0.37 * (*count - 1) : 0);
            window->setProperty("panX", base + 0.37 * *count);
            window->grabWindow().save(QString::fromLocal8Bit(dir) + QString("/frame_%1.png").arg(*count, 3, 10, QChar('0')));
            if (++*count >= 40) { timer->stop(); window->setProperty("allowClose", true); app.quit(); }
        });
        QTimer::singleShot(1500, timer, [timer] { timer->start(40); });
    }
    return app.exec();
}
