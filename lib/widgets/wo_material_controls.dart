import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Material 控件兼容层，保留统一命名以兼容现有业务页面。
class WoFilledButton extends StatelessWidget {
  const WoFilledButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  })  : _tonal = false,
        _prefix = null;

  const WoFilledButton.tonal({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  })  : _tonal = true,
        _prefix = null;

  const WoFilledButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
    this.style,
  })  : child = label,
        _prefix = icon,
        _tonal = false;

  const WoFilledButton.tonalIcon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
    this.style,
  })  : child = label,
        _prefix = icon,
        _tonal = true;

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final Widget? _prefix;
  final bool _tonal;

  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    OutlinedBorder? shape,
    TextStyle? textStyle,
    double? elevation,
  }) =>
      FilledButton.styleFrom(
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        padding: padding,
        minimumSize: minimumSize,
        shape: shape,
        textStyle: textStyle,
        elevation: elevation,
      );

  @override
  Widget build(BuildContext context) {
    final prefix = _prefix;
    if (prefix != null) {
      return _tonal
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              style: style,
              icon: prefix,
              label: child,
            )
          : FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: prefix,
              label: child,
            );
    }
    return _tonal
        ? FilledButton.tonal(onPressed: onPressed, style: style, child: child)
        : FilledButton(onPressed: onPressed, style: style, child: child);
  }
}

class WoOutlinedButton extends StatelessWidget {
  const WoOutlinedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  }) : _prefix = null;

  const WoOutlinedButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
    this.style,
  })  : child = label,
        _prefix = icon;

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final Widget? _prefix;

  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    BorderSide? side,
    OutlinedBorder? shape,
    TextStyle? textStyle,
  }) =>
      OutlinedButton.styleFrom(
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        padding: padding,
        minimumSize: minimumSize,
        side: side,
        shape: shape,
        textStyle: textStyle,
      );

  @override
  Widget build(BuildContext context) {
    final prefix = _prefix;
    return prefix == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: prefix,
            label: child,
          );
  }
}

class WoTextButton extends StatelessWidget {
  const WoTextButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  }) : _prefix = null;

  const WoTextButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
    this.style,
  })  : child = label,
        _prefix = icon;

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final Widget? _prefix;

  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    OutlinedBorder? shape,
    TextStyle? textStyle,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
  }) =>
      TextButton.styleFrom(
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        padding: padding,
        minimumSize: minimumSize,
        shape: shape,
        textStyle: textStyle,
        visualDensity: visualDensity,
        tapTargetSize: tapTargetSize,
      );

  @override
  Widget build(BuildContext context) {
    final prefix = _prefix;
    return prefix == null
        ? TextButton(onPressed: onPressed, style: style, child: child)
        : TextButton.icon(
            onPressed: onPressed,
            style: style,
            icon: prefix,
            label: child,
          );
  }
}

/// Material 列表行。
class WoListTile extends StatelessWidget {
  const WoListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.selected = false,
    this.dense,
    this.contentPadding,
    this.visualDensity,
    this.shape,
    this.tileColor,
    this.selectedTileColor,
    this.horizontalTitleGap,
    this.minLeadingWidth,
    this.minVerticalPadding,
    this.isThreeLine = false,
    this.titleTextStyle,
    this.subtitleTextStyle,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool selected;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final VisualDensity? visualDensity;
  final ShapeBorder? shape;
  final Color? tileColor;
  final Color? selectedTileColor;
  final double? horizontalTitleGap;
  final double? minLeadingWidth;
  final double? minVerticalPadding;
  final bool isThreeLine;
  final TextStyle? titleTextStyle;
  final TextStyle? subtitleTextStyle;

  @override
  Widget build(BuildContext context) => ListTile(
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: trailing,
        onTap: onTap,
        onLongPress: onLongPress,
        enabled: enabled,
        selected: selected,
        dense: dense,
        contentPadding: contentPadding,
        visualDensity: visualDensity,
        shape: shape,
        tileColor: tileColor,
        selectedTileColor: selectedTileColor,
        horizontalTitleGap: horizontalTitleGap,
        minLeadingWidth: minLeadingWidth,
        minVerticalPadding: minVerticalPadding,
        isThreeLine: isThreeLine,
        titleTextStyle: titleTextStyle,
        subtitleTextStyle: subtitleTextStyle,
      );
}

/// Material 图标按钮。
class WoIconButton extends StatelessWidget {
  const WoIconButton({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding = const EdgeInsets.all(8),
    this.alignment = Alignment.center,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.disabledColor,
    required this.onPressed,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback = true,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    required this.icon,
  });

  final double? iconSize;
  final VisualDensity? visualDensity;
  final EdgeInsetsGeometry padding;
  final AlignmentGeometry alignment;
  final double? splashRadius;
  final Color? color;
  final Color? focusColor;
  final Color? hoverColor;
  final Color? highlightColor;
  final Color? disabledColor;
  final VoidCallback? onPressed;
  final MouseCursor? mouseCursor;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? tooltip;
  final bool enableFeedback;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final bool? isSelected;
  final Widget? selectedIcon;
  final Widget icon;

  @override
  Widget build(BuildContext context) => IconButton(
        iconSize: iconSize,
        visualDensity: visualDensity,
        padding: padding,
        alignment: alignment,
        splashRadius: splashRadius,
        color: color,
        focusColor: focusColor,
        hoverColor: hoverColor,
        highlightColor: highlightColor,
        disabledColor: disabledColor,
        onPressed: onPressed,
        mouseCursor: mouseCursor,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
        enableFeedback: enableFeedback,
        constraints: constraints,
        style: style,
        isSelected: isSelected,
        selectedIcon: selectedIcon,
        icon: icon,
      );
}

/// Material 线性进度。
class WoLinearProgressIndicator extends StatelessWidget {
  const WoLinearProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.valueColor,
    this.minHeight,
    this.semanticsLabel,
    this.semanticsValue,
    this.borderRadius,
  });

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double? minHeight;
  final String? semanticsLabel;
  final String? semanticsValue;
  final BorderRadiusGeometry? borderRadius;

  @override
  Widget build(BuildContext context) => LinearProgressIndicator(
        value: value,
        backgroundColor: backgroundColor,
        color: color,
        valueColor: valueColor,
        minHeight: minHeight,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
        borderRadius: borderRadius,
      );
}

/// Material 滑杆。
class WoSlider extends StatelessWidget {
  const WoSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
    this.inactiveColor,
    this.secondaryActiveColor,
    this.thumbColor,
    this.overlayColor,
    this.mouseCursor,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.allowedInteraction,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? secondaryActiveColor;
  final Color? thumbColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final MouseCursor? mouseCursor;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  final SliderInteraction? allowedInteraction;

  @override
  Widget build(BuildContext context) => Slider(
        value: value,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        secondaryActiveColor: secondaryActiveColor,
        thumbColor: thumbColor,
        overlayColor: overlayColor,
        mouseCursor: mouseCursor,
        semanticFormatterCallback: semanticFormatterCallback,
        focusNode: focusNode,
        autofocus: autofocus,
        allowedInteraction: allowedInteraction,
      );
}

/// Material 开关。
class WoSwitch extends StatelessWidget {
  const WoSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
    this.label,
    this.description,
    this.leadingLabel = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? activeThumbColor;
  final Color? activeTrackColor;
  final Color? inactiveThumbColor;
  final Color? inactiveTrackColor;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final Widget? label;
  final Widget? description;
  final bool leadingLabel;

  @override
  Widget build(BuildContext context) {
    final control = Switch(
      value: value,
      onChanged: onChanged,
      activeColor: activeColor,
      activeThumbColor: activeThumbColor,
      activeTrackColor: activeTrackColor,
      inactiveThumbColor: inactiveThumbColor,
      inactiveTrackColor: inactiveTrackColor,
      autofocus: autofocus,
      focusNode: focusNode,
      onFocusChange: onFocusChange,
    );
    if (label == null && description == null) return control;
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) label!,
        if (description != null) description!,
      ],
    );
    return Row(
      children: leadingLabel
          ? [Expanded(child: text), control]
          : [control, const SizedBox(width: 12), Expanded(child: text)],
    );
  }
}

/// Material 开关列表项。
class WoSwitchListTile extends StatelessWidget {
  const WoSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.isThreeLine = false,
    this.dense,
    this.contentPadding,
    this.selected = false,
    this.autofocus = false,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.tileColor,
    this.selectedTileColor,
    this.shape,
    this.controlAffinity = ListTileControlAffinity.trailing,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final bool isThreeLine;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final bool selected;
  final bool autofocus;
  final Color? activeColor;
  final Color? activeThumbColor;
  final Color? activeTrackColor;
  final Color? inactiveThumbColor;
  final Color? inactiveTrackColor;
  final Color? tileColor;
  final Color? selectedTileColor;
  final ShapeBorder? shape;
  final ListTileControlAffinity controlAffinity;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
        isThreeLine: isThreeLine,
        dense: dense,
        contentPadding: contentPadding,
        selected: selected,
        autofocus: autofocus,
        activeColor: activeColor,
        activeThumbColor: activeThumbColor,
        activeTrackColor: activeTrackColor,
        inactiveThumbColor: inactiveThumbColor,
        inactiveTrackColor: inactiveTrackColor,
        tileColor: tileColor,
        selectedTileColor: selectedTileColor,
        shape: shape,
        controlAffinity: controlAffinity,
      );
}

/// Material 复选列表项。
class WoCheckboxListTile extends StatelessWidget {
  const WoCheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.controlAffinity = ListTileControlAffinity.trailing,
    this.tristate = false,
    this.selected = false,
    this.dense,
    this.contentPadding,
    this.activeColor,
    this.checkColor,
    this.tileColor,
    this.selectedTileColor,
    this.shape,
  });

  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final ListTileControlAffinity controlAffinity;
  final bool tristate;
  final bool selected;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final Color? activeColor;
  final Color? checkColor;
  final Color? tileColor;
  final Color? selectedTileColor;
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
        controlAffinity: controlAffinity,
        tristate: tristate,
        selected: selected,
        dense: dense,
        contentPadding: contentPadding,
        activeColor: activeColor,
        checkColor: checkColor,
        tileColor: tileColor,
        selectedTileColor: selectedTileColor,
        shape: shape,
      );
}

/// Material 浮动按钮。
class WoFloatingActionButton extends StatelessWidget {
  const WoFloatingActionButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.tooltip,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.heroTag = const _DefaultHeroTag(),
    this.focusNode,
    this.autofocus = false,
    this.mini = false,
    this.shape,
    this.clipBehavior = Clip.none,
  })  : _icon = null,
        _extended = false;

  const WoFloatingActionButton.extended({
    super.key,
    required this.onPressed,
    required Widget label,
    Widget? icon,
    this.tooltip,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.heroTag = const _DefaultHeroTag(),
    this.focusNode,
    this.autofocus = false,
    this.shape,
    this.clipBehavior = Clip.none,
  })  : child = label,
        _icon = icon,
        mini = false,
        _extended = true;

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? _icon;
  final bool _extended;
  final String? tooltip;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double? elevation;
  final Object? heroTag;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool mini;
  final ShapeBorder? shape;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    return _extended
        ? FloatingActionButton.extended(
            onPressed: onPressed,
            icon: _icon,
            label: child,
            tooltip: tooltip,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            elevation: elevation,
            heroTag: heroTag,
            focusNode: focusNode,
            autofocus: autofocus,
            shape: shape,
            clipBehavior: clipBehavior,
          )
        : FloatingActionButton(
            onPressed: onPressed,
            tooltip: tooltip,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            elevation: elevation,
            heroTag: heroTag,
            focusNode: focusNode,
            autofocus: autofocus,
            mini: mini,
            shape: shape,
            clipBehavior: clipBehavior,
            child: child,
          );
  }
}

class _DefaultHeroTag {
  const _DefaultHeroTag();
}

/// Material 单选 chip。
class WoChoiceChip extends StatelessWidget {
  const WoChoiceChip({
    super.key,
    this.avatar,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.labelStyle,
    this.labelPadding,
    this.selectedColor,
    this.disabledColor,
    this.padding,
    this.visualDensity,
    this.side,
    this.shape,
    this.showCheckmark,
    this.checkmarkColor,
    this.backgroundColor,
    this.elevation,
    this.pressElevation,
    this.tooltip,
    this.materialTapTargetSize,
    this.iconTheme,
  });

  final Widget? avatar;
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final Color? selectedColor;
  final Color? disabledColor;
  final EdgeInsetsGeometry? padding;
  final VisualDensity? visualDensity;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final bool? showCheckmark;
  final Color? checkmarkColor;
  final Color? backgroundColor;
  final double? elevation;
  final double? pressElevation;
  final String? tooltip;
  final MaterialTapTargetSize? materialTapTargetSize;
  final IconThemeData? iconTheme;

  @override
  Widget build(BuildContext context) => ChoiceChip(
        avatar: avatar,
        label: label,
        selected: selected,
        onSelected: onSelected,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        selectedColor: selectedColor,
        disabledColor: disabledColor,
        padding: padding,
        visualDensity: visualDensity,
        side: side,
        shape: shape,
        showCheckmark: showCheckmark,
        checkmarkColor: checkmarkColor,
        backgroundColor: backgroundColor,
        elevation: elevation,
        pressElevation: pressElevation,
        tooltip: tooltip,
        materialTapTargetSize: materialTapTargetSize,
        iconTheme: iconTheme,
      );
}

class WoFilterChip extends WoChoiceChip {
  const WoFilterChip({
    super.key,
    super.avatar,
    required super.label,
    required super.selected,
    required super.onSelected,
    super.labelStyle,
    super.labelPadding,
    super.selectedColor,
    super.disabledColor,
    super.padding,
    super.visualDensity,
    super.side,
    super.shape,
    super.showCheckmark,
    super.checkmarkColor,
    super.backgroundColor,
    super.elevation,
    super.pressElevation,
    super.tooltip,
    super.materialTapTargetSize,
    super.iconTheme,
  });

  @override
  Widget build(BuildContext context) => FilterChip(
        avatar: avatar,
        label: label,
        selected: selected,
        onSelected: onSelected,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        selectedColor: selectedColor,
        disabledColor: disabledColor,
        padding: padding,
        visualDensity: visualDensity,
        side: side,
        shape: shape,
        showCheckmark: showCheckmark,
        checkmarkColor: checkmarkColor,
        backgroundColor: backgroundColor,
        elevation: elevation,
        pressElevation: pressElevation,
        tooltip: tooltip,
        materialTapTargetSize: materialTapTargetSize,
        iconTheme: iconTheme,
      );
}

/// Material 下拉选项。
class WoDropdownButton<T> extends StatelessWidget {
  const WoDropdownButton({
    super.key,
    required this.items,
    this.value,
    this.hint,
    this.disabledHint,
    required this.onChanged,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24,
    this.isDense = false,
    this.isExpanded = false,
    this.itemHeight,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
  });

  final List<DropdownMenuItem<T>>? items;
  final T? value;
  final Widget? hint;
  final Widget? disabledHint;
  final ValueChanged<T?>? onChanged;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        hint: hint,
        disabledHint: disabledHint,
        onTap: onTap,
        elevation: elevation,
        style: style,
        icon: icon,
        iconDisabledColor: iconDisabledColor,
        iconEnabledColor: iconEnabledColor,
        iconSize: iconSize,
        isDense: isDense,
        isExpanded: isExpanded,
        itemHeight: itemHeight,
        focusColor: focusColor,
        focusNode: focusNode,
        autofocus: autofocus,
        dropdownColor: dropdownColor,
        menuMaxHeight: menuMaxHeight,
        enableFeedback: enableFeedback,
        alignment: alignment,
        borderRadius: borderRadius,
      );
}

class WoDropdownButtonFormField<T> extends StatelessWidget {
  const WoDropdownButtonFormField({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.onSaved,
    this.validator,
    this.autovalidateMode = AutovalidateMode.disabled,
    this.decoration = const InputDecoration(),
    this.hint,
    this.disabledHint,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24,
    this.isDense = true,
    this.isExpanded = false,
    this.itemHeight,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
  }) : assert(value == null || initialValue == null);

  final T? value;
  final T? initialValue;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final FormFieldSetter<T>? onSaved;
  final FormFieldValidator<T>? validator;
  final AutovalidateMode autovalidateMode;
  final InputDecoration decoration;
  final Widget? hint;
  final Widget? disabledHint;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        value: value,
        initialValue: initialValue,
        items: items,
        onChanged: onChanged,
        onSaved: onSaved,
        validator: validator,
        autovalidateMode: autovalidateMode,
        decoration: decoration,
        hint: hint,
        disabledHint: disabledHint,
        onTap: onTap,
        elevation: elevation,
        style: style,
        icon: icon,
        iconDisabledColor: iconDisabledColor,
        iconEnabledColor: iconEnabledColor,
        iconSize: iconSize,
        isDense: isDense,
        isExpanded: isExpanded,
        itemHeight: itemHeight,
        focusColor: focusColor,
        focusNode: focusNode,
        autofocus: autofocus,
        dropdownColor: dropdownColor,
        menuMaxHeight: menuMaxHeight,
        enableFeedback: enableFeedback,
        alignment: alignment,
        borderRadius: borderRadius,
      );
}

/// Material 输入框。
class WoTextField extends StatelessWidget {
  const WoTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.textDirection,
    this.autofocus = false,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.readOnly = false,
    this.showCursor,
    this.maxLength,
    this.maxLengthEnforcement,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.inputFormatters,
    this.enabled,
    this.enableInteractiveSelection = true,
    this.scrollPhysics,
    this.scrollController,
    this.autofillHints,
    this.restorationId,
    this.canRequestFocus = true,
    this.style,
    this.cursorColor,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final TextDirection? textDirection;
  final bool autofocus;
  final String obscuringCharacter;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final bool readOnly;
  final bool? showCursor;
  final int? maxLength;
  final MaxLengthEnforcement? maxLengthEnforcement;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final TapRegionCallback? onTapOutside;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final bool enableInteractiveSelection;
  final ScrollPhysics? scrollPhysics;
  final ScrollController? scrollController;
  final Iterable<String>? autofillHints;
  final String? restorationId;
  final bool canRequestFocus;
  final TextStyle? style;
  final Color? cursorColor;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        textAlign: textAlign,
        textAlignVertical: textAlignVertical,
        textDirection: textDirection,
        autofocus: autofocus,
        obscuringCharacter: obscuringCharacter,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        minLines: minLines,
        maxLines: maxLines,
        expands: expands,
        readOnly: readOnly,
        showCursor: showCursor,
        maxLength: maxLength,
        maxLengthEnforcement: maxLengthEnforcement,
        onTap: onTap,
        onTapOutside: onTapOutside,
        onEditingComplete: onEditingComplete,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        inputFormatters: inputFormatters,
        enabled: enabled,
        enableInteractiveSelection: enableInteractiveSelection,
        scrollPhysics: scrollPhysics,
        scrollController: scrollController,
        autofillHints: autofillHints,
        restorationId: restorationId,
        canRequestFocus: canRequestFocus,
        style: style,
        cursorColor: cursorColor,
      );
}

/// Material 表单输入框。
class WoTextFormField extends StatelessWidget {
  const WoTextFormField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.textAlign = TextAlign.start,
    this.autofocus = false,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.readOnly = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.inputFormatters,
    this.enabled,
    this.onSaved,
    this.validator,
    this.autovalidateMode = AutovalidateMode.disabled,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextAlign textAlign;
  final bool autofocus;
  final String obscuringCharacter;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final bool readOnly;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final FormFieldSetter<String>? onSaved;
  final FormFieldValidator<String>? validator;
  final AutovalidateMode autovalidateMode;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        initialValue: initialValue,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        textAlign: textAlign,
        autofocus: autofocus,
        obscuringCharacter: obscuringCharacter,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        minLines: minLines,
        maxLines: maxLines,
        expands: expands,
        readOnly: readOnly,
        maxLength: maxLength,
        onTap: onTap,
        onEditingComplete: onEditingComplete,
        onFieldSubmitted: onSubmitted,
        onChanged: onChanged,
        inputFormatters: inputFormatters,
        enabled: enabled,
        onSaved: onSaved,
        validator: validator,
        autovalidateMode: autovalidateMode,
      );
}

/// Material 对话框入口。
Future<T?> showWoDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      anchorPoint: anchorPoint,
      builder: builder,
    );

/// Material `AlertDialog` 兼容层。
class WoAlertDialog extends StatelessWidget {
  const WoAlertDialog({
    super.key,
    this.icon,
    this.iconPadding,
    this.iconColor,
    this.title,
    this.titlePadding,
    this.titleTextStyle,
    this.content,
    this.contentPadding,
    this.contentTextStyle,
    this.actions,
    this.actionsPadding,
    this.actionsAlignment,
    this.actionsOverflowAlignment,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.buttonPadding,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticLabel,
    this.insetPadding,
    this.clipBehavior = Clip.none,
    this.shape,
    this.alignment,
    this.scrollable = false,
  });

  final Widget? icon;
  final EdgeInsetsGeometry? iconPadding;
  final Color? iconColor;
  final Widget? title;
  final EdgeInsetsGeometry? titlePadding;
  final TextStyle? titleTextStyle;
  final Widget? content;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? contentTextStyle;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment? actionsAlignment;
  final OverflowBarAlignment? actionsOverflowAlignment;
  final VerticalDirection? actionsOverflowDirection;
  final double? actionsOverflowButtonSpacing;
  final EdgeInsetsGeometry? buttonPadding;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final String? semanticLabel;
  final EdgeInsets? insetPadding;
  final Clip clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final bool scrollable;

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: icon,
        iconPadding: iconPadding,
        iconColor: iconColor,
        title: title,
        titlePadding: titlePadding,
        titleTextStyle: titleTextStyle,
        content: content,
        contentPadding: contentPadding,
        contentTextStyle: contentTextStyle,
        actions: actions,
        actionsPadding: actionsPadding,
        actionsAlignment: actionsAlignment,
        actionsOverflowAlignment: actionsOverflowAlignment,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
        buttonPadding: buttonPadding,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding: insetPadding,
        clipBehavior: clipBehavior,
        shape: shape,
        alignment: alignment,
        scrollable: scrollable,
      );
}

/// Material 底部弹层入口。
Future<T?> showWoModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9 / 16,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) =>
    showModalBottomSheet<T>(
      context: context,
      backgroundColor: backgroundColor,
      barrierLabel: barrierLabel,
      elevation: elevation,
      shape: shape,
      clipBehavior: clipBehavior,
      constraints: constraints,
      barrierColor: barrierColor,
      isScrollControlled: isScrollControlled,
      scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
      useRootNavigator: useRootNavigator,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      routeSettings: routeSettings,
      transitionAnimationController: transitionAnimationController,
      anchorPoint: anchorPoint,
      sheetAnimationStyle: sheetAnimationStyle,
      requestFocus: requestFocus,
      builder: builder,
    );

/// Material SnackBar 兼容层。
class WoSnackBar extends SnackBar {
  const WoSnackBar({
    super.key,
    required Widget content,
    Color? backgroundColor,
    double? elevation,
    EdgeInsetsGeometry? margin,
    EdgeInsetsGeometry? padding,
    double? width,
    ShapeBorder? shape,
    SnackBarBehavior? behavior,
    SnackBarAction? action,
    double? actionOverflowThreshold,
    bool? showCloseIcon,
    Color? closeIconColor,
    Duration duration = const Duration(seconds: 4),
    Animation<double>? animation,
    VoidCallback? onVisible,
    DismissDirection dismissDirection = DismissDirection.down,
    Clip clipBehavior = Clip.hardEdge,
  }) : super(
          content: content,
          backgroundColor: backgroundColor,
          elevation: elevation,
          margin: margin,
          padding: padding,
          width: width,
          shape: shape,
          behavior: behavior,
          action: action,
          actionOverflowThreshold: actionOverflowThreshold,
          showCloseIcon: showCloseIcon,
          closeIconColor: closeIconColor,
          duration: duration,
          animation: animation,
          onVisible: onVisible,
          dismissDirection: dismissDirection,
          clipBehavior: clipBehavior,
        );
}

/// Material 加载指示器。
class WoProgressIndicator extends StatelessWidget {
  const WoProgressIndicator({
    super.key,
    this.strokeWidth,
    this.color,
    this.valueColor,
    this.value,
    this.backgroundColor,
    this.semanticsLabel,
    this.semanticsValue,
  });

  final double? strokeWidth;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double? value;
  final Color? backgroundColor;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  Widget build(BuildContext context) => CircularProgressIndicator(
        strokeWidth: strokeWidth ?? 4,
        color: color,
        valueColor: valueColor,
        value: value,
        backgroundColor: backgroundColor,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
      );
}
