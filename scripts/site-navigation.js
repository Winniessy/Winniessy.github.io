(function () {
  'use strict';

  var sectionLabels = {
    linux: 'Linux 学习之旅',
    mcu: 'MCU 学习之旅',
    projects: '项目记录',
    notes: '其他学习笔记'
  };

  function normalizeRoute(value) {
    var route = value || '';
    var hashIndex = route.indexOf('#');
    if (hashIndex >= 0) route = route.slice(hashIndex + 1);
    route = route.split('?')[0];

    try {
      route = decodeURIComponent(route);
    } catch (error) {
      // Keep the encoded route if it contains malformed escape characters.
    }

    if (!route.startsWith('/')) route = '/' + route;
    route = route.replace(/\/README(?:\.md)?$/i, '/');
    route = route.replace(/\.md$/i, '');
    if (/^\/(linux|mcu|projects|notes)$/.test(route)) route += '/';
    return route || '/';
  }

  function currentRoute() {
    return normalizeRoute(window.location.hash || '/');
  }

  function articleSection(route) {
    var match = route.match(/^\/(linux|mcu|projects|notes)\//);
    return match ? match[1] : '';
  }

  function isArticleRoute(route) {
    var section = articleSection(route);
    return Boolean(section && route !== '/' + section + '/');
  }

  function createLink(href, text) {
    var link = document.createElement('a');
    link.href = href;
    link.textContent = text;
    return link;
  }

  function headingItems(article) {
    return Array.prototype.slice.call(article.querySelectorAll('h2, h3')).map(function (heading) {
      var anchor = heading.querySelector('a.anchor');
      if (!anchor) return null;
      return {
        href: anchor.getAttribute('href'),
        label: heading.textContent.trim(),
        level: heading.tagName === 'H3' ? 3 : 2
      };
    }).filter(Boolean);
  }

  function createTocList(items) {
    var list = document.createElement('ol');
    items.forEach(function (item) {
      var listItem = document.createElement('li');
      listItem.className = 'toc-level-' + item.level;
      listItem.appendChild(createLink(item.href, item.label));
      list.appendChild(listItem);
    });
    return list;
  }

  function renderToc(article, items) {
    var oldAside = document.querySelector('.page-toc');
    if (oldAside) oldAside.remove();
    document.body.classList.remove('has-page-toc');

    if (!items.length) return;

    var aside = document.createElement('aside');
    aside.className = 'page-toc';
    aside.setAttribute('aria-label', '本页目录');
    var title = document.createElement('strong');
    title.textContent = '本页目录';
    aside.appendChild(title);
    aside.appendChild(createTocList(items));
    document.body.appendChild(aside);
    document.body.classList.add('has-page-toc');

    var details = document.createElement('details');
    details.className = 'article-inline-toc';
    var summary = document.createElement('summary');
    summary.textContent = '本页目录';
    details.appendChild(summary);
    details.appendChild(createTocList(items));

    var firstHeading = article.querySelector('h1');
    if (firstHeading && firstHeading.nextSibling) {
      article.insertBefore(details, firstHeading.nextSibling);
    } else {
      article.insertBefore(details, article.firstChild);
    }
  }

  function renderBreadcrumb(article, route) {
    var oldBreadcrumb = article.querySelector('.article-breadcrumb');
    if (oldBreadcrumb) oldBreadcrumb.remove();

    var section = articleSection(route);
    if (!section) return;

    var heading = article.querySelector('h1');
    var breadcrumb = document.createElement('nav');
    breadcrumb.className = 'article-breadcrumb';
    breadcrumb.setAttribute('aria-label', '面包屑导航');
    breadcrumb.appendChild(createLink('#/', '首页'));

    var separator = document.createElement('span');
    separator.setAttribute('aria-hidden', 'true');
    separator.textContent = '/';
    breadcrumb.appendChild(separator);
    breadcrumb.appendChild(createLink('#/' + section + '/', sectionLabels[section]));

    if (heading) {
      var secondSeparator = document.createElement('span');
      secondSeparator.setAttribute('aria-hidden', 'true');
      secondSeparator.textContent = '/';
      breadcrumb.appendChild(secondSeparator);
      var current = document.createElement('span');
      current.textContent = heading.textContent.trim();
      breadcrumb.appendChild(current);
    }

    article.insertBefore(breadcrumb, article.firstChild);
  }

  function sidebarArticles(current) {
    var rootList = document.querySelector('.sidebar-nav > ul');
    var currentLink = Array.prototype.slice.call(document.querySelectorAll('.sidebar-nav a[href]')).find(function (link) {
      return normalizeRoute(link.getAttribute('href')) === current;
    });
    var group = currentLink ? currentLink.parentElement : null;

    while (group && rootList && group.parentElement !== rootList) {
      group = group.parentElement;
    }

    var scope = group || document.querySelector('.sidebar-nav');
    var seen = {};
    return Array.prototype.slice.call(scope.querySelectorAll('a[href]')).map(function (link) {
      var href = link.getAttribute('href');
      var route = normalizeRoute(href);
      if (!isArticleRoute(route) || seen[route]) return null;
      seen[route] = true;
      return {
        href: href,
        route: route,
        label: link.textContent.trim()
      };
    }).filter(Boolean);
  }

  function pagerLink(item, direction) {
    if (!item) {
      var placeholder = document.createElement('div');
      placeholder.className = 'article-pager-placeholder';
      return placeholder;
    }

    var link = createLink(item.href, '');
    link.className = 'article-pager-link ' + direction;
    var label = document.createElement('span');
    label.className = 'article-pager-label';
    label.textContent = direction === 'previous' ? '上一篇' : '下一篇';
    var title = document.createElement('span');
    title.className = 'article-pager-title';
    title.textContent = item.label;
    link.appendChild(label);
    link.appendChild(title);
    return link;
  }

  function renderPager(article, route) {
    var oldPager = article.querySelector('.article-pager');
    if (oldPager) oldPager.remove();

    var articles = sidebarArticles(route);
    var currentIndex = articles.findIndex(function (item) {
      return item.route === route;
    });

    var pager = document.createElement('nav');
    pager.className = 'article-pager';
    pager.setAttribute('aria-label', '文章导航');
    var homeLink = createLink('#/', '← 返回首页');
    homeLink.className = 'article-pager-home';
    pager.appendChild(homeLink);

    var grid = document.createElement('div');
    grid.className = 'article-pager-grid';
    grid.appendChild(pagerLink(currentIndex > 0 ? articles[currentIndex - 1] : null, 'previous'));
    grid.appendChild(pagerLink(currentIndex >= 0 && currentIndex < articles.length - 1 ? articles[currentIndex + 1] : null, 'next'));
    pager.appendChild(grid);
    article.appendChild(pager);
  }

  function renderArticleNavigation() {
    var article = document.querySelector('.markdown-section');
    var route = currentRoute();
    var oldAside = document.querySelector('.page-toc');
    if (oldAside) oldAside.remove();
    document.body.classList.remove('has-page-toc');

    if (!article || !isArticleRoute(route)) return;
    renderBreadcrumb(article, route);
    renderToc(article, headingItems(article));
    renderPager(article, route);
  }

  function siteNavigationPlugin(hook) {
    hook.doneEach(function () {
      window.setTimeout(renderArticleNavigation, 0);
    });
  }

  window.$docsify = window.$docsify || {};
  window.$docsify.plugins = [].concat(siteNavigationPlugin, window.$docsify.plugins || []);
}());
