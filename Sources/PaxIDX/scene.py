# scene.py — PaxIDX 圖形橋接的 scene 模組（Pythonista 常用子集）
# 節點樹架在 _paxscene（C 橋）的 UIView 上：座標 y 軸向上、場景中心為原點
# （world 容器做了 y 翻轉），z_rotation 與 SpriteKit 同向（正值逆時針）。
# 目標相容範圍：Node／ShapeNode／LabelNode／Scene／run——夠跑
# Pythonista 的 AnalogClock.py 這類範例。
from collections import namedtuple

import _paxscene
import ui  # noqa: F401  （讓 from scene import * 的程式能直接用 ui.Path）

Size = namedtuple('Size', ('w', 'h'))
Point = namedtuple('Point', ('x', 'y'))

_NAMED_COLORS = {
    'black': (0, 0, 0, 1), 'white': (1, 1, 1, 1), 'red': (1, 0, 0, 1),
    'green': (0, 1, 0, 1), 'blue': (0, 0, 1, 1), 'yellow': (1, 1, 0, 1),
    'cyan': (0, 1, 1, 1), 'magenta': (1, 0, 1, 1), 'orange': (1, 0.5, 0, 1),
    'purple': (0.5, 0, 0.5, 1), 'brown': (0.6, 0.4, 0.2, 1),
    'silver': (0.75, 0.75, 0.75, 1), 'gray': (0.5, 0.5, 0.5, 1),
    'grey': (0.5, 0.5, 0.5, 1), 'darkgray': (0.33, 0.33, 0.33, 1),
    'lightgray': (0.83, 0.83, 0.83, 1), 'clear': (0, 0, 0, 0),
    'transparent': (0, 0, 0, 0),
}


def _parse_color(c):
    """顏色（名稱字串／#hex／(r,g,b[,a])／有 rgba 屬性的物件）→ (r,g,b,a) 或 None"""
    if c is None:
        return None
    if isinstance(c, str):
        s = c.strip().lower()
        if s in _NAMED_COLORS:
            return _NAMED_COLORS[s]
        if s.startswith('#'):
            h = s[1:]
            try:
                if len(h) == 3:
                    return tuple(int(ch * 2, 16) / 255.0 for ch in h) + (1.0,)
                if len(h) == 6:
                    return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0,
                            int(h[4:6], 16) / 255.0, 1.0)
            except ValueError:
                return None
        return None
    if isinstance(c, (tuple, list)) and len(c) in (3, 4):
        vals = [float(v) for v in c]
        if any(v > 1.0 for v in vals):
            vals = [v / 255.0 for v in vals]
        if len(vals) == 3:
            vals.append(1.0)
        return tuple(vals)
    if all(hasattr(c, a) for a in ('red', 'green', 'blue')):
        return (float(c.red), float(c.green), float(c.blue),
                float(getattr(c, 'alpha', 1.0)))
    return None


class Node:
    def __init__(self, _view=None):
        self._view = _view if _view is not None else _paxscene.view_create(0)
        self._children = []
        self._parent = None
        self._position = (0.0, 0.0)
        self._anchor_point = (0.5, 0.5)
        self._z_rotation = 0.0
        self._alpha = 1.0
        _paxscene.view_set_anchor(self._view, 0.5, 0.5)
        # 先把預設位置推給 C 橋存著：position 常在 add_child 之前設定，
        # C 橋要在入樹時按父節點原點補上偏移（見 PySceneBridge）
        _paxscene.view_set_position(self._view, 0.0, 0.0)

    # --- 樹 ---
    @property
    def children(self):
        return list(self._children)

    @property
    def parent(self):
        return self._parent

    def add_child(self, node):
        if node._parent is not None:
            node.remove_from_parent()
        node._parent = self
        self._children.append(node)
        _paxscene.view_add_child(self._view, node._view)

    def remove_from_parent(self):
        if self._parent is not None:
            self._parent._children.remove(self)
            self._parent = None
        _paxscene.view_remove_from_parent(self._view)

    # --- 幾何與外觀 ---
    @property
    def position(self):
        return Point(*self._position)

    @position.setter
    def position(self, value):
        self._position = (float(value[0]), float(value[1]))
        _paxscene.view_set_position(self._view, *self._position)

    @property
    def anchor_point(self):
        return self._anchor_point

    @anchor_point.setter
    def anchor_point(self, value):
        self._anchor_point = (float(value[0]), float(value[1]))
        _paxscene.view_set_anchor(self._view, *self._anchor_point)

    @property
    def z_rotation(self):
        return self._z_rotation

    @z_rotation.setter
    def z_rotation(self, value):
        self._z_rotation = float(value)
        _paxscene.view_set_rotation(self._view, self._z_rotation)

    @property
    def alpha(self):
        return self._alpha

    @alpha.setter
    def alpha(self, value):
        self._alpha = float(value)
        _paxscene.view_set_alpha(self._view, self._alpha)


class ShapeNode(Node):
    def __init__(self, path=None, fill_color=None, stroke_color=None, shadow=None):
        super().__init__(_view=_paxscene.view_create(1))
        self._path = path
        self._fill_color = fill_color
        self._stroke_color = stroke_color
        if path is not None:
            self._apply_shape()
        if shadow is not None:
            s_color, s_dx, s_dy, s_blur = shadow
            rgba = _parse_color(s_color) or (0, 0, 0, 1)
            _paxscene.shape_set_shadow(self._view, rgba, float(s_dx), float(s_dy), float(s_blur))

    def _apply_shape(self):
        _paxscene.shape_set(self._view, self._path._handle,
                            _parse_color(self._fill_color),
                            _parse_color(self._stroke_color),
                            float(self._path.line_width))

    @property
    def fill_color(self):
        return self._fill_color

    @fill_color.setter
    def fill_color(self, value):
        self._fill_color = value
        if self._path is not None:
            self._apply_shape()

    @property
    def stroke_color(self):
        return self._stroke_color

    @stroke_color.setter
    def stroke_color(self, value):
        self._stroke_color = value
        if self._path is not None:
            self._apply_shape()


class LabelNode(Node):
    def __init__(self, text='', font=None, color='white'):
        super().__init__(_view=_paxscene.view_create(2))
        self._text = str(text)
        self._font = font if font is not None else ('Helvetica', 20.0)
        self._color = color
        self._apply_label()

    def _apply_label(self):
        name, size = self._font
        rgba = _parse_color(self._color) or (1, 1, 1, 1)
        _paxscene.label_set(self._view, self._text, str(name), float(size), rgba)

    @property
    def text(self):
        return self._text

    @text.setter
    def text(self, value):
        self._text = str(value)
        self._apply_label()

    @property
    def font(self):
        return self._font

    @font.setter
    def font(self, value):
        self._font = value
        self._apply_label()

    @property
    def color(self):
        return self._color

    @color.setter
    def color(self, value):
        self._color = value
        rgba = _parse_color(value) or (1, 1, 1, 1)
        _paxscene.label_set_color(self._view, rgba)


class Scene(Node):
    """全屏場景：子節點進 world 容器（y 向上、中心原點）。子類覆寫
    setup()／update()／did_change_size() 即可。"""

    def __init__(self):
        super().__init__()
        self._world_node = Node()
        # world 原點＝畫面左下角（Pythonista 場景座標）：anchor 設 (0,0)，
        # C 橋佈局時把它的 position 釘在左下角並做 y 翻轉
        self._world_node.anchor_point = (0, 0)
        _paxscene.view_flip_y(self._world_node._view)
        _paxscene.view_add_child(self._view, self._world_node._view)
        self._background_color = 'black'

    def add_child(self, node):
        self._world_node.add_child(node)

    @property
    def children(self):
        return self._world_node.children

    @property
    def size(self):
        return Size(*_paxscene.screen_size())

    @property
    def background_color(self):
        return self._background_color

    @background_color.setter
    def background_color(self, value):
        self._background_color = value
        rgba = _parse_color(value)
        if rgba is not None:
            _paxscene.scene_set_bg(self._view, rgba)

    # 子類覆寫點（預設空實作，C 橋每幀／事件直接呼叫）
    def setup(self):
        pass

    def update(self):
        pass

    def did_change_size(self):
        pass


def run(scene, *args, **kwargs):
    """呈現場景（全屏，右上角 ✕ 關閉）。frame_interval 等 Pythonista
    參數先收下不用。"""
    _paxscene.scene_present(scene._view, scene._world_node._view, scene)
