# ui.py — PaxIDX 圖形橋接的 ui 模組（Pythonista 常用子集）
# 目前只有 Path（路徑）：給 scene.ShapeNode 畫形狀用。
# 路徑物件包著 _paxscene（C 橋）的 UIBezierPath 句柄。
import _paxscene


class Path:
    def __init__(self, handle):
        self._handle = handle
        self._line_width = 1.0

    @property
    def line_width(self):
        return self._line_width

    @line_width.setter
    def line_width(self, value):
        self._line_width = float(value)
        _paxscene.path_set_line_width(self._handle, self._line_width)

    @property
    def bounds(self):
        return _paxscene.path_bounds(self._handle)

    @classmethod
    def oval(cls, x, y, width, height):
        return cls(_paxscene.path_oval(float(x), float(y), float(width), float(height)))

    @classmethod
    def rect(cls, x, y, width, height):
        return cls(_paxscene.path_rect(float(x), float(y), float(width), float(height)))

    @classmethod
    def rounded_rect(cls, x, y, width, height, corner_radius):
        return cls(_paxscene.path_rounded_rect(float(x), float(y), float(width),
                                               float(height), float(corner_radius)))
