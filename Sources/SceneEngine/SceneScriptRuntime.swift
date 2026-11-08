/// The JavaScript scenes' scripts run against: Wallpaper Engine's script API as far as a video needs it (vectors, the
/// WEMath/WEColor/WEVector modules, layers, `shared`, script properties, timers). Things a video can't have do nothing:
/// the cursor rests at the canvas center and never clicks, sound buffers stay silent, shortcuts don't open.
///
/// SceneScripts calls `__host.setup(config)` once, `__host.load(index, factory)` for each script (the script wrapped in a
/// function, see SceneScripts.wrap), then `__host.start()`, and `__host.run(ticks)` to move time on; `__host.state()`
/// returns every object's values as JSON and `__host.problems()` what went wrong.
enum SceneScriptRuntime {
    static let source = #"""
'use strict';
var __host = (function () {
    // MARK: Vectors

    const KEYS = ['x', 'y', 'z', 'w'];

    /// The first `n` numbers in the arguments: numbers, "x y z" strings, arrays or {x, y, z} objects, in order. A single
    /// number fills every component; missing ones are 0.
    function parts(args, n) {
        const out = [];
        for (const a of args) {
            if (a === null || a === undefined) continue;
            if (typeof a === 'number' || typeof a === 'boolean') out.push(+a);
            else if (typeof a === 'string') out.push(...a.trim().split(/[\s,]+/).map(Number));
            else if (Array.isArray(a) || ArrayBuffer.isView(a)) out.push(...Array.from(a, Number));
            else if (typeof a === 'object') for (const k of KEYS) if (a[k] !== undefined) out.push(+a[k]);
        }
        if (out.length === 1) while (out.length < n) out.push(out[0]);
        while (out.length < n) out.push(0);
        return out.slice(0, n).map(v => (Number.isFinite(v) ? v : 0));
    }

    function vectorClass(n) {
        const keys = KEYS.slice(0, n);
        const V = class {
            constructor(...args) {
                const p = parts(args, n);
                keys.forEach((k, i) => { this[k] = p[i]; });
            }
        };
        const each = f => function (v) {
            const o = parts([v], n);
            return new V(...keys.map((k, i) => f(this[k], o[i])));
        };
        Object.assign(V.prototype, {
            add: each((a, b) => a + b),
            subtract: each((a, b) => a - b),
            multiply: each((a, b) => a * b),
            divide: each((a, b) => a / b),
            min: each(Math.min),
            max: each(Math.max),
            dot(v) { const o = parts([v], n); return keys.reduce((s, k, i) => s + this[k] * o[i], 0); },
            lengthSqr() { return this.dot(this); },
            length() { return Math.sqrt(this.lengthSqr()); },
            normalize() { const l = this.length(); return l > 0 ? this.divide(l) : this.copy(); },
            copy() { return new V(this); },
            negate() { return this.multiply(-1); },
            abs() { return new V(...keys.map(k => Math.abs(this[k]))); },
            floor() { return new V(...keys.map(k => Math.floor(this[k]))); },
            ceil() { return new V(...keys.map(k => Math.ceil(this[k]))); },
            round() { return new V(...keys.map(k => Math.round(this[k]))); },
            mix(v, t) { const o = parts([v], n); return new V(...keys.map((k, i) => this[k] + (o[i] - this[k]) * t)); },
            distance(v) { return this.subtract(v).length(); },
            equals(v) { const o = parts([v], n); return keys.every((k, i) => this[k] === o[i]); },
            toString() { return keys.map(k => this[k]).join(' '); },
        });
        return V;
    }
    const Vec2 = vectorClass(2), Vec3 = vectorClass(3), Vec4 = vectorClass(4);
    Vec3.prototype.cross = function (v) {
        const o = parts([v], 3);
        return new Vec3(this.y * o[2] - this.z * o[1], this.z * o[0] - this.x * o[2], this.x * o[1] - this.y * o[0]);
    };

    // MARK: Modules

    const WEMath = Object.freeze({
        PI: Math.PI,
        deg2rad: Math.PI / 180,
        rad2deg: 180 / Math.PI,
        mix(a, b, t) { return a !== null && typeof a === 'object' && a.mix ? a.mix(b, t) : a + (b - a) * t; },
        smoothStep(min, max, v) {
            if (min === max) return v < min ? 0 : 1;
            const t = Math.min(Math.max((v - min) / (max - min), 0), 1);
            return t * t * (3 - 2 * t);
        },
        clamp(v, min, max) { return Math.min(Math.max(v, min), max); },
        fract(v) { return v - Math.floor(v); },
        sign: Math.sign,
        step(edge, v) { return v < edge ? 0 : 1; },
    });

    const WEColor = Object.freeze({
        /// Hue, saturation and value (each 0…1) to red, green and blue.
        hsv2rgb(c) {
            const v3 = new Vec3(c), h = (((v3.x % 1) + 1) % 1) * 6, s = v3.y, v = v3.z;
            const i = Math.floor(h), f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
            return new Vec3(...[[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6]);
        },
        rgb2hsv(c) {
            const { x: r, y: g, z: b } = new Vec3(c), max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
            let h = 0;
            if (d > 0) h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
            return new Vec3((((h / 6) % 1) + 1) % 1, max > 0 ? d / max : 0, max);
        },
        normalizeColor(c) { return new Vec3(c).divide(255); },
        expandColor(c) { return new Vec3(c).multiply(255); },
    });

    const WEVector = Object.freeze({
        /// Degrees to a unit vector, and back.
        angleVector2(angle) { const r = angle * Math.PI / 180; return new Vec2(Math.cos(r), Math.sin(r)); },
        vectorAngle2(v) { const p = parts([v], 2); return Math.atan2(p[1], p[0]) * 180 / Math.PI; },
    });

    const modules = { WEMath, WEColor, WEVector };
    function module(name) {
        if (!(name in modules)) throw new Error(`module '${name}' isn't available`);
        return modules[name];
    }

    // MARK: Time, randomness, problems

    let config, tick = 0;
    const problems = new Set();
    function problem(text) { if (problems.size < 64) problems.add(String(text).slice(0, 300)); }
    function seconds() { return tick * config.tick; }

    // The scene's clock: the chosen time of day at scene time 0, moving with the scene.
    const RealDate = Date;
    class SceneDate extends RealDate {
        constructor(...args) { if (args.length === 0) super(SceneDate.now()); else super(...args); }
        static now() { return config.clockStart + (seconds() - config.warmUp) * 1000; }
    }
    globalThis.Date = SceneDate;

    // Seeded, so every run of the scene is the same (a loop's two passes must agree).
    let seed = 0x2545F491;
    Math.random = function () {
        seed = (seed + 0x6D2B79F5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };

    const timers = new Map();
    let nextTimer = 1;
    function addTimer(callback, ms, repeats) {
        if (typeof callback !== 'function') return 0;
        const delay = Math.max(0, Number(ms) || 0) / 1000;
        timers.set(nextTimer, { callback, at: seconds() + delay, every: repeats ? Math.max(delay, config.tick) : 0 });
        return nextTimer++;
    }
    function runTimers() {
        for (const [id, timer] of [...timers]) {
            if (seconds() + 1e-9 < timer.at) continue;
            if (timer.every) timer.at += timer.every; else timers.delete(id);
            try { timer.callback(); } catch (e) { problem(`A script's timer failed: ${e}`); }
        }
    }

    // MARK: Layers

    const VECTORS = { origin: 3, scale: 3, angles: 3, color: 3, size: 2, parallaxDepth: 2 };
    const NUMBERS = ['alpha', 'brightness', 'pointsize'];

    class Layer {
        constructor(o) {
            Object.defineProperties(this, {
                __id: { value: o.id }, __parent: { value: o.parent },
                __effects: { value: (o.effects || []).map(e => ({ name: e.name, visible: !!e.visible })) },
                __values: { value: {} },
            });
            this.name = o.name;
            this.origin = new Vec3(o.origin);
            this.scale = new Vec3(o.scale);
            this.angles = new Vec3(o.angles);
            this.parallaxDepth = new Vec2(o.parallaxDepth);
            this.size = new Vec2(o.size);
            this.visible = !!o.visible;
            this.alpha = o.alpha;
            this.color = new Vec3(o.color);
            this.brightness = o.brightness;
            this.text = '';
            this.pointsize = 32;
        }
        getParent() { return byID.get(this.__parent) || null; }
        getChildren() { return layers.filter(l => l.__parent === this.__id); }
        getEffect(key) {
            const effects = this.__effects;
            const effect = typeof key === 'number' ? effects[key] : effects.find(e => e.name === key);
            return effect || null;
        }
        getEffectCount() { return this.__effects.length; }
        getTextureAnimation() { return animation; }
        getAnimation() { return animation; }
        play() {}
        stop() {}
        pause() {}
        isPlaying() { return false; }
    }
    // Sprite and model animations keep playing on their own; scripts can't steer them here.
    const animation = Object.freeze({
        play() {}, pause() {}, stop() {}, isPlaying() { return true; }, setFrame() {}, getFrame() { return 0; },
        frameCount: 1, rate: 1, duration: 0,
    });

    let layers = [], byID = new Map(), created = [];

    // MARK: Values by path ("origin", "effects/0/visible", "effects/0/passes/1/constantshadervalues/strength")

    function parse(value) {
        if (typeof value === 'string') {
            const p = value.trim().split(/\s+/);
            if (p.length >= 2 && p.length <= 4 && p.every(s => s !== '' && Number.isFinite(Number(s)))) {
                return new [Vec2, Vec3, Vec4][p.length - 2](value);
            }
        }
        return value;
    }

    function get(layer, path, saved) {
        if (path in VECTORS || NUMBERS.includes(path) || path === 'visible' || path === 'text') {
            const value = layer[path];
            return value !== null && typeof value === 'object' && value.copy ? value.copy() : value;
        }
        const effect = /^effects\/(\d+)\/visible$/.exec(path);
        if (effect && layer.__effects[+effect[1]]) return layer.__effects[+effect[1]].visible;
        return path in layer.__values ? layer.__values[path] : parse(saved);
    }

    function set(layer, path, value) {
        if (path in VECTORS) layer[path] = new [Vec2, Vec3, Vec4][VECTORS[path] - 2](value);
        else if (NUMBERS.includes(path)) layer[path] = Number(value);
        else if (path === 'visible') layer.visible = !!value;
        else if (path === 'text') layer.text = String(value);
        else {
            const effect = /^effects\/(\d+)\/visible$/.exec(path);
            if (effect && layer.__effects[+effect[1]]) layer.__effects[+effect[1]].visible = !!value;
            else layer.__values[path] = value;
        }
    }

    // MARK: Script properties

    function propertyBuilder(sceneValues) {
        const declared = {};
        const builder = new Proxy({}, {
            get(_, key) {
                if (key === 'finish') return () => {
                    const result = {};
                    for (const [name, d] of Object.entries(declared)) result[name] = d.value;
                    for (const [name, value] of Object.entries(sceneValues || {})) {
                        const d = declared[name];
                        if (d && (d.kind === 'addColor' || (d.value !== null && typeof d.value === 'object'))) {
                            result[name] = new Vec3(value);
                        } else if (d && typeof d.value === 'number') {
                            result[name] = Number(value);
                        } else if (d && typeof d.value === 'boolean') {
                            result[name] = value === true || value === 1 || value === 'true' || value === '1';
                        } else {
                            result[name] = value;
                        }
                    }
                    return result;
                };
                if (typeof key === 'string' && key.startsWith('add')) {
                    return options => {
                        if (options && options.name) declared[options.name] = { kind: key, value: options.value };
                        return builder;
                    };
                }
                return undefined;
            },
        });
        return builder;
    }

    // MARK: The engine's globals

    const storage = new Map();
    const engine = {
        timeOfDay: 0.5, frametime: 0, runtime: 0,
        get canvasSize() { return new Vec2(config.canvas); },
        get screenResolution() { return new Vec2(config.screen); },
        userProperties: {},
        AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
        registerAudioBuffers(n) {
            const size = [16, 32, 64].includes(n) ? n : 64;
            return { left: new Float32Array(size), right: new Float32Array(size), average: new Float32Array(size), resolution: size };
        },
        isDesktopDevice() { return true; },
        isMobileDevice() { return false; },
        isWallpaper() { return true; },
        isScreenSaver() { return false; },
        isRunningInEditor() { return false; },
        openUserShortcut() {},
        setTimeout(callback, ms) { return addTimer(callback, ms, false); },
        setInterval(callback, ms) { return addTimer(callback, ms, true); },
        clearTimeout(id) { timers.delete(id); },
        clearInterval(id) { timers.delete(id); },
    };
    const input = {
        get cursorWorldPosition() { return new Vec3(config.canvas[0] / 2, config.canvas[1] / 2, 0); },
        get cursorScreenPosition() { return new Vec2(config.screen[0] / 2, config.screen[1] / 2); },
        cursorLeftDown: false, cursorRightDown: false,
    };
    const thisScene = {
        getLayer(key) { return typeof key === 'number' ? layers[key] || null : layers.find(l => l.name === key) || null; },
        getLayerCount() { return layers.length; },
        getLayerIndex(layer) { return layers.indexOf(layer); },
        enumerateLayers() { return layers.slice(); },
        createLayer(o) {
            const layer = new Layer({ id: -1, name: (o && o.name) || '', origin: o && o.origin, scale: (o && o.scale) || 1,
                                      angles: o && o.angles, size: o && o.size, visible: true, alpha: 1, color: 1, brightness: 1 });
            created.push(layer);
            return layer;
        },
        destroyLayer() {},
        sortLayer() {},
    };
    const localStorage = {
        get(key) { return storage.get(String(key)); },
        set(key, value) { storage.set(String(key), value); },
        delete(key) { storage.delete(String(key)); },
        clear() { storage.clear(); },
    };
    const quiet = () => {};
    const console = { log: quiet, info: quiet, warn: quiet, error: quiet, debug: quiet };
    Object.assign(globalThis, {
        Vec2, Vec3, Vec4, WEMath, WEColor, WEVector, engine, input, thisScene, shared: {}, localStorage, console,
        setTimeout: engine.setTimeout, setInterval: engine.setInterval,
        clearTimeout: engine.clearTimeout, clearInterval: engine.clearInterval,
    });

    // MARK: Scripts

    const scripts = [];

    function describe(script) { return `Script on “${script.layer.name}” (${script.path})`; }

    function call(script, name) {
        const f = script.exports && script.exports[name];
        if (script.failed || typeof f !== 'function') return;
        try {
            const result = f.call(undefined, get(script.layer, script.path, script.saved));
            if (result !== undefined) set(script.layer, script.path, result);
        } catch (e) {
            script.failed = true;
            problem(`${describe(script)}: ${e}`);
        }
    }

    function number(v) { return Number.isFinite(+v) ? +v : 0; }

    function value(v) {
        if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'string') return v;
        if (v !== null && typeof v === 'object') {
            const p = KEYS.filter(k => v[k] !== undefined);
            return p.length ? parts([v], p.length) : null;
        }
        return null;
    }

    return {
        setup(c) {
            config = c;
            engine.timeOfDay = c.timeOfDay;
            engine.userProperties = c.userProperties;
            layers = c.objects.map(o => new Layer(o));
            byID = new Map(layers.map(l => [l.__id, l]));
        },
        module,
        load(index, factory) {
            const s = config.scripts[index];
            const layer = byID.get(s.object);
            const script = { layer, path: s.path, saved: s.value, exports: null, failed: false };
            scripts.push(script);
            if (!layer) { script.failed = true; return; }
            if (s.path === 'text') layer.text = String(s.value);
            if (s.path === 'pointsize') layer.pointsize = number(s.value);
            try {
                script.exports = factory(layer, layer, () => propertyBuilder(s.properties));
            } catch (e) {
                script.failed = true;
                problem(`${describe(script)}: ${e}`);
            }
        },
        start() {
            engine.frametime = config.tick;
            for (const script of scripts) call(script, 'init');
        },
        run(ticks) {
            for (let i = 0; i < ticks; i++) {
                tick += 1;
                engine.frametime = config.tick;
                engine.runtime = seconds();
                runTimers();
                for (const script of scripts) call(script, 'update');
            }
        },
        state() {
            if (created.some(l => l.visible)) problem('Layers that scripts add aren\'t drawn');
            return JSON.stringify(layers.map(l => ({
                id: l.__id,
                origin: parts([l.origin], 3), scale: parts([l.scale], 3), angles: parts([l.angles], 3),
                visible: !!l.visible, alpha: number(l.alpha), color: parts([l.color], 3), brightness: number(l.brightness),
                effects: l.__effects.map(e => !!e.visible),
                values: Object.fromEntries(Object.entries(l.__values).map(([k, v]) => [k, value(v)])),
            })));
        },
        problems() { return [...problems]; },
    };
})();
"""#
}
