(function () {
  'use strict';

  var storagePrefix = 'winniessy-sidebar-collapsed:';
  var bindScheduled = false;

  function readState(key) {
    try {
      return window.localStorage.getItem(storagePrefix + key) === '1';
    } catch (error) {
      return false;
    }
  }

  function writeState(key, collapsed) {
    try {
      window.localStorage.setItem(storagePrefix + key, collapsed ? '1' : '0');
    } catch (error) {
      // The sidebar still works when localStorage is unavailable.
    }
  }

  function directChild(element, tagName) {
    return Array.prototype.slice.call(element.children).find(function (child) {
      return child.tagName === tagName;
    });
  }

  function sectionKey(item, title, index) {
    var normalized = title.trim().toLowerCase().replace(/\s+/g, '-');
    return normalized || String(index);
  }

  function setCollapsed(item, key, collapsed) {
    item.classList.toggle('is-collapsed', collapsed);
    var trigger = item.querySelector(':scope > .sidebar-section-toggle');
    if (trigger) trigger.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    writeState(key, collapsed);
  }

  function bindSidebar() {
    bindScheduled = false;
    var sidebar = document.querySelector('.sidebar-nav');
    if (!sidebar) return;

    var rootList = directChild(sidebar, 'UL');
    if (!rootList) return;

    Array.prototype.forEach.call(rootList.children, function (item, index) {
      if (item.tagName !== 'LI') return;

      var nestedList = directChild(item, 'UL');
      if (!nestedList) return;

      var trigger = Array.prototype.slice.call(item.children).find(function (child) {
        return child.tagName === 'P' || child.tagName === 'A';
      });
      if (!trigger) return;

      if (!trigger.classList.contains('sidebar-section-toggle')) {
        trigger.classList.add('sidebar-section-toggle');
        trigger.setAttribute('role', 'button');
        trigger.setAttribute('tabindex', '0');

        var title = trigger.textContent || '';
        var key = sectionKey(item, title, index);
        item.dataset.sidebarSectionKey = key;

        trigger.addEventListener('click', function (event) {
          if (trigger.tagName === 'A') event.preventDefault();
          setCollapsed(item, key, !item.classList.contains('is-collapsed'));
        });

        trigger.addEventListener('keydown', function (event) {
          if (event.key !== 'Enter' && event.key !== ' ') return;
          event.preventDefault();
          setCollapsed(item, key, !item.classList.contains('is-collapsed'));
        });
      }

      var key = item.dataset.sidebarSectionKey || sectionKey(item, trigger.textContent || '', index);
      setCollapsed(item, key, readState(key));
    });
  }

  function scheduleBind() {
    if (bindScheduled) return;
    bindScheduled = true;
    window.setTimeout(bindSidebar, 0);
  }

  function start() {
    scheduleBind();
    var observer = new MutationObserver(scheduleBind);
    observer.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
}());
