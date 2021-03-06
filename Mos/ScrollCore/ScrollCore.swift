//
//  ScrollCore.swift
//  Mos
//  滚动事件截取与插值计算核心类
//  Created by Caldis on 2017/1/14.
//  Copyright © 2017年 Caldis. All rights reserved.
//

import Cocoa

class ScrollCore {
    
    // 单例
    static let shared = ScrollCore()
    init() { print("Class 'ScrollCore' is initialized") }
    
    // 鼠标事件轴
    let axis = ( Y: UInt32(1), X: UInt32(1), YX: UInt32(2), YXZ: UInt32(3) )
    // 滚动数据
    var scrollCurr   = ( y: 0.0, x: 0.0 )  // 当前滚动距离
    var scrollBuffer = ( y: 0.0, x: 0.0 )  // 滚动缓冲距离
    var scrollDelta  = ( y: 0.0, x: 0.0 )  // 滚动方向记录
    // 热键数据
    var dashScroll = false
    var dashAmplification = 1.0
    var toggleScroll = false
    var blockSmooth = false
    // 插值数据
    var smoothStep = Options.shared.scrollAdvanced.step
    var smoothSpeed = Options.shared.scrollAdvanced.speed
    var smoothDuration = Options.shared.scrollAdvanced.durationTransition
    // 目标应用数据
    var previousScrollTargetProcessID = 0.0 // 用于在鼠标移动到不同窗口时停止滚动
    // 例外应用数据
    var exceptionalApplication: ExceptionalApplication?
    var currentExceptionalApplication: ExceptionalApplication? // 用于区分按下热键及抬起时的作用目标
    // 滚动数值滤波, 用于去除滚动的起始抖动
    var scrollFiller = ScrollFiller()
    // 事件发送器
    var scrollEventPoster: CVDisplayLink?
    // 拦截层
    var scrollEventHeadInterceptor: Interceptor?
    var scrollEventTailInterceptor: Interceptor?
    var hotkeyEventInterceptor: Interceptor?
    var mouseEventInterceptor: Interceptor?
    var tapKeeperTimer: Timer?
    // 拦截掩码
    let scrollEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let hotkeyEventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    let mouseLeftEventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    let mouseRightEventMask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
    
    // 滚动事件截取处理:头部
    let scrollEventHeadCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 是否返回原始事件 (不启用平滑时)
        var returnOriginalEvent = true
        // 判断输入源 (无法区分黑苹果, 因为黑苹果的触控板驱动直接模拟鼠标输入)
        // 当鼠标输入, 根据需要执行翻转方向/平滑滚动
        if ScrollUtils.shared.isMouse(of: event) {
            // 获取目标窗口 BundleID
            let targetBID = ScrollUtils.shared.getBundleIdFromMouseLocation(and: event)
            // 获取列表中应用程序的列外设置信息
            ScrollCore.shared.exceptionalApplication = ScrollUtils.shared.applicationInExceptionalApplications(bundleId: targetBID)
            // 平滑/翻转
            let enableSmooth = ScrollUtils.shared.isEnableSmoothOn(application: ScrollCore.shared.exceptionalApplication, targetBundleId: targetBID, flag: ScrollCore.shared.blockSmooth)
            let enableReverse = ScrollUtils.shared.isEnableReverseOn(application: ScrollCore.shared.exceptionalApplication, targetBundleId: targetBID)
            // 滚动参数
            ScrollCore.shared.smoothStep = ScrollUtils.shared.optionsStepOn(application: ScrollCore.shared.exceptionalApplication)
            ScrollCore.shared.smoothSpeed = ScrollUtils.shared.optionsSpeedOn(application: ScrollCore.shared.exceptionalApplication)
            ScrollCore.shared.smoothDuration = ScrollUtils.shared.optionsDurationTransitionOn(application: ScrollCore.shared.exceptionalApplication)
            // 处理滚动事件
            let scrollEvent = ScrollEvent(with: event)
            // Y轴
            if scrollEvent.Y.usable {
                // 是否翻转滚动
                if enableReverse {
                    ScrollEventUtils.reverseY(scrollEvent)
                }
                // 是否平滑滚动
                if enableSmooth {
                    // 禁止返回原始事件
                    returnOriginalEvent = false
                    // 如果输入值为非 Fixed 类型, 则使用 Step 作为门限值将数据归一化
                    if !scrollEvent.Y.fixed {
                        ScrollEventUtils.normalizeY(scrollEvent, ScrollCore.shared.smoothStep)
                    }
                }
            }
            // X轴
            if scrollEvent.X.usable {
                // 是否翻转滚动
                if enableReverse {
                    ScrollEventUtils.reverseX(scrollEvent)
                }
                // 是否平滑滚动
                if enableSmooth {
                    // 禁止返回原始事件
                    returnOriginalEvent = false
                    // 如果输入值为非 Fixed 类型, 则使用 Step 作为门限值将数据归一化
                    if !scrollEvent.X.fixed {
                        ScrollEventUtils.normalizeX(scrollEvent, ScrollCore.shared.smoothStep)
                    }
                }
            }
            // 触发滚动事件推送
            if enableSmooth {
                ScrollCore.shared.updateScrollBuffer(
                    y: scrollEvent.Y.usableValue,
                    x: scrollEvent.X.usableValue,
                    s: ScrollCore.shared.smoothSpeed,
                    a: ScrollCore.shared.dashAmplification
                )
                ScrollCore.shared.enableScrollEventPoster()
            }
        }
        // 返回事件对象
        if returnOriginalEvent {
            return Unmanaged.passUnretained(event)
        } else {
            return nil
        }
    }
    
    // 滚动事件截取处理:尾部
    let scrollEventTailCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        let currentProcessID = event.getDoubleValueField(.eventTargetUnixProcessID)
        if (ScrollCore.shared.previousScrollTargetProcessID != 0.0 && ScrollCore.shared.previousScrollTargetProcessID != currentProcessID) {
            ScrollCore.shared.pauseHandlingScroll()
        }
        ScrollCore.shared.previousScrollTargetProcessID = currentProcessID
        return nil
    }
    
    // 热键事件处理
    let hotkeyEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 获取当前按键
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // 获取目标应用程序
        let targetBID = ScrollUtils.shared.getBundleIdFromMouseLocation(and: event)
        let targetAppliaction = ScrollUtils.shared.applicationInExceptionalApplications(bundleId: targetBID)
        // 判断快捷键
        switch keyCode {
            case MODIFIER_KEY.controlLeft, MODIFIER_KEY.controlRight:
                let down = Utils.isControlDown(event)
                ScrollCore.shared.tryToggleEnableAllFlag(for: targetAppliaction, with: keyCode, using: MODIFIER_KEY.controlPair, on: down)
            case MODIFIER_KEY.optionLeft, MODIFIER_KEY.optionRight:
                let down = Utils.isOptionDown(event)
                ScrollCore.shared.tryToggleEnableAllFlag(for: targetAppliaction, with: keyCode, using: MODIFIER_KEY.optionPair, on: down)
            case MODIFIER_KEY.commandLeft, MODIFIER_KEY.commandRight:
                let down = Utils.isCommandDown(event)
                ScrollCore.shared.tryToggleEnableAllFlag(for: targetAppliaction, with: keyCode, using: MODIFIER_KEY.commandPair, on: down)
            case MODIFIER_KEY.shiftLeft, MODIFIER_KEY.shiftRight:
                let down = Utils.isShiftDown(event)
                ScrollCore.shared.tryToggleEnableAllFlag(for: targetAppliaction, with: keyCode, using: MODIFIER_KEY.shiftPair, on: down)
            default: break
        }
        return nil
    }
    func tryEnableDashFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.dashScroll = true
            ScrollCore.shared.dashAmplification = 5.0
        }
    }
    func tryEnableToggleFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.toggleScroll = true
        }
    }
    func tryEnableBlockFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.blockSmooth = true
            ScrollCore.shared.scrollBuffer = ScrollCore.shared.scrollCurr
        }
    }
    func tryDisableDashFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.dashScroll = false
            ScrollCore.shared.dashAmplification = 1.0
        }
    }
    func tryDisableToggleFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.toggleScroll = false
        }
    }
    func tryDisableBlockFlag(with key:CGKeyCode, andKeyPair keyPair:[CGKeyCode]) {
        if (keyPair.contains(key)) {
            ScrollCore.shared.blockSmooth = false
        }
    }
    func disableAllFlag() {
        ScrollCore.shared.dashScroll = false
        ScrollCore.shared.dashAmplification = 1.0
        ScrollCore.shared.toggleScroll = false
        ScrollCore.shared.blockSmooth = false
    }
    func tryToggleEnableAllFlag(for targetAppliaction:ExceptionalApplication?, with keyCode:CGKeyCode, using keyPair:[CGKeyCode], on down:Bool) {
        // 读取快捷键
        let dashKey = ScrollUtils.shared.optionsDashOn(application: targetAppliaction)
        let toggleKey = ScrollUtils.shared.optionsToggleOn(application: targetAppliaction)
        let blockKey = ScrollUtils.shared.optionsBlockOn(application: targetAppliaction)
        if down {
            // 如果按下, 则按需激活
            ScrollCore.shared.tryEnableDashFlag(with: dashKey, andKeyPair: keyPair)
            ScrollCore.shared.tryEnableToggleFlag(with: toggleKey, andKeyPair: keyPair)
            ScrollCore.shared.tryEnableBlockFlag(with: blockKey, andKeyPair: keyPair)
            // 并更新记录器
            ScrollCore.shared.currentExceptionalApplication = targetAppliaction
        } else if ScrollCore.shared.currentExceptionalApplication == targetAppliaction {
            // 如果弹起, 且与先前的目标应用相同, 则按需关闭
            ScrollCore.shared.tryDisableDashFlag(with: dashKey, andKeyPair: keyPair)
            ScrollCore.shared.tryDisableToggleFlag(with: toggleKey, andKeyPair: keyPair)
            ScrollCore.shared.tryDisableBlockFlag(with: blockKey, andKeyPair: keyPair)
        } else {
            // 否则关闭全部
            ScrollCore.shared.disableAllFlag()
            // 并更新记录器
            ScrollCore.shared.currentExceptionalApplication = nil
        }
    }
    
    // 鼠标事件处理
    let mouseLeftEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 如果点击左键则停止滚动
        ScrollCore.shared.pauseHandlingScroll()
        return nil
    }
    
    // 启动滚动处理
    func startHandlingScroll() {
        // 截取事件
        scrollEventHeadInterceptor = Interceptor(
            event: scrollEventMask,
            handleBy: scrollEventHeadCallBack,
            listenOn: .cghidEventTap,
            placeAt: .tailAppendEventTap,
            for: .defaultTap
        )
        // CPU占用上升了将近一倍...
        // scrollEventTailInterceptor = Interceptor(
        //     event: scrollEventMask,
        //     handleBy: scrollEventTailCallBack,
        //     listenOn: .cgAnnotatedSessionEventTap,
        //     placeAt: .tailAppendEventTap,
        //     for: .listenOnly
        // )
        hotkeyEventInterceptor = Interceptor(
            event: hotkeyEventMask,
            handleBy: hotkeyEventCallBack,
            listenOn: .cghidEventTap,
            placeAt: .tailAppendEventTap,
            for: .listenOnly
        )
        mouseEventInterceptor = Interceptor(
            event: mouseLeftEventMask,
            handleBy: mouseLeftEventCallBack,
            listenOn: .cghidEventTap,
            placeAt: .tailAppendEventTap,
            for: .listenOnly
        )
        // 初始化滚动事件发送器
        initScrollEventPoster()
        // 初始化守护进程
        tapKeeperTimer = Timer.scheduledTimer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(tapKeeper),
            userInfo: nil,
            repeats: true
        )
    }
    // 暂停滚动处理
    func pauseHandlingScroll() {
        cleanScrollBuffer()
        disableScrollEventPoster()
        previousScrollTargetProcessID = 0.0
    }
    // 停止滚动处理
    func endHandlingScroll() {
        // 停止守护进程
        tapKeeperTimer?.invalidate()
        // 停止滚动事件发送器
        disableScrollEventPoster()
        // 停止截取事件
        scrollEventHeadInterceptor?.stop()
        scrollEventTailInterceptor?.stop()
        hotkeyEventInterceptor?.stop()
        mouseEventInterceptor?.stop()
    }
    // 守护进程
    @objc func tapKeeper() {
        scrollEventHeadInterceptor?.check()
        scrollEventTailInterceptor?.check()
        hotkeyEventInterceptor?.check()
        mouseEventInterceptor?.check()
    }
        
    // 鼠标数据控制
    func updateScrollBuffer(y: Double, x: Double, s: Double, a: Double = 1) {
        // 更新 Y 轴数据
        if y*scrollDelta.y > 0 {
            scrollBuffer.y += y * s * a
        } else {
            scrollBuffer.y = y * s * a
            scrollCurr.y = 0.0
        }
        // 更新 X 轴数据
        if x*scrollDelta.x > 0 {
            scrollBuffer.x += x * s * a
        } else {
            scrollBuffer.x = x * s * a
            scrollCurr.x = 0.0
        }
        scrollDelta = ( y: y, x: x )
    }
    func cleanScrollBuffer() {
        // 重置数值
        scrollCurr = ( y: 0.0, x: 0.0 )
        scrollBuffer = ( y: 0.0, x: 0.0 )
        scrollDelta = ( y: 0.0, x: 0.0 )
        // 重置插值器
        scrollFiller.clean()
    }
    
    // 鼠标插值数据输出
    // 初始化 CVDisplayLink
    func initScrollEventPoster() {
        // 新建一个 CVDisplayLinkSetOutputCallback 来执行循环
        CVDisplayLinkCreateWithActiveCGDisplays(&scrollEventPoster)
        CVDisplayLinkSetOutputCallback(scrollEventPoster!, {
            (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in ScrollCore.shared.handleScroll()
            return kCVReturnSuccess
        }, nil)
    }
    // 启动事件发送器
    func enableScrollEventPoster() {
        if !CVDisplayLinkIsRunning(scrollEventPoster!) {
            CVDisplayLinkStart(scrollEventPoster!)
        }
    }
    // 停止事件发送器
    func disableScrollEventPoster() {
        if let poster = scrollEventPoster {
            CVDisplayLinkStop(poster)
        }
    }
    
    // 根据需要变换滚动方向
    func weapScrollIfToggling(with nextValue: ( y: Double, x: Double ), toggling: Bool) -> (y: Double, x: Double) {
        // 如果按下 Shift, 则始终将滚动转为横向
        if toggling {
            // 判断哪个轴有值, 有值则赋给 X
            // 某些鼠标 (MXMaster/MXAnywhere), 按下 Shift 后会显式转换方向为横向, 此处针对这类转换进行归一化处理
            if nextValue.y != 0.0 && nextValue.x == 0.0 {
                return (y: nextValue.x, x: nextValue.y)
            } else {
                return (y: nextValue.y, x: nextValue.x)
            }
        } else {
            return (y: nextValue.y, x: nextValue.x)
        }
    }
    // 处理滚动事件
    func handleScroll() {
        // 计算插值
        let scrollPulse = (
            y: Interpolator.lerp(src: scrollCurr.y, dest: scrollBuffer.y, trans: smoothDuration),
            x: Interpolator.lerp(src: scrollCurr.x, dest: scrollBuffer.x, trans: smoothDuration)
        )
        // 更新滚动位置
        scrollCurr = (
            y: scrollCurr.y + scrollPulse.y,
            x: scrollCurr.x + scrollPulse.x
        )
        // 平滑滚动结果
        let filteredValue = scrollFiller.fillIn(with: scrollPulse)
        // 变换滚动结果
        let swapedValue = weapScrollIfToggling(with: filteredValue, toggling: toggleScroll)
        // 发送滚动结果
        MouseEvent.scroll(axis.YX, yScroll: Int32(swapedValue.y), xScroll: Int32(swapedValue.x))
        // 如果临近目标距离小于精确度门限则暂停滚动
        if scrollPulse.y.magnitude<=Options.shared.scrollAdvanced.precision && scrollPulse.x.magnitude<=Options.shared.scrollAdvanced.precision {
            pauseHandlingScroll()
        }
    }
    
}
