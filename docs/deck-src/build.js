const pptxgen = require('pptxgenjs');
const React = require('react');
const ReactDOMServer = require('react-dom/server');
const sharp = require('sharp');
const fa = require('react-icons/fa');
const { applyTheme } = require('/mnt/skills/public/pptx/scripts/apply_theme.js');

const THEME = {
  name: 'AIy guide', headFontFace: 'Calibri', bodyFontFace: 'Calibri',
  colors: { dk1: '141A36', lt1: 'FFFFFF', dk2: '0B1026', lt2: 'F2F4FF', accent1: '4F6BFF', accent2: '7A4DFF', accent3: '12A150', accent4: 'F5A300', accent5: 'E5484D', accent6: '6B7394', hlink: '4F6BFF', folHlink: '7A4DFF' },
};

async function icon(Icon, hex = '#FFFFFF') {
  const svg = ReactDOMServer.renderToStaticMarkup(React.createElement(Icon, { color: hex, size: 256 }));
  const buf = await sharp(Buffer.from(svg)).png().toBuffer();
  return 'image/png;base64,' + buf.toString('base64');
}

(async () => {
  const pres = new pptxgen();
  pres.layout = 'LAYOUT_WIDE'; // 13.33 x 7.5
  pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
  pres.title = 'AIy: a simple guide';
  pres.author = 'AIy';
  const C = pres.SchemeColor;

  // ------------------------------------------------------------------ layouts
  const footer = (dark) => [
    { text: { text: 'AIy: a simple guide', options: { x: 0.6, y: 7.02, w: 4, h: 0.3, fontSize: 11, color: dark ? C.background2 : C.accent6, margin: 0 } } },
  ];
  const contentLayout = (name, titleW) => pres.defineSlideMaster({
    title: name, background: { color: C.background2 },
    objects: [
      { placeholder: { options: { name: 'title', type: 'title', x: 0.6, y: 0.42, w: titleW, h: 1.15, fontSize: 36, bold: true, color: C.text2, valign: 'top', align: 'left', margin: 0 }, text: '' } },
      ...footer(false),
    ],
    slideNumber: { x: 12.3, y: 7.02, w: 0.45, h: 0.3, fontSize: 11, color: C.accent6, align: 'right' },
  });
  contentLayout('CONTENT', 8.4);
  contentLayout('CONTENT_NARROW', 5.9);
  contentLayout('CONTENT_WIDE', 12.1);
  pres.defineSlideMaster({
    title: 'DARK', background: { color: C.text2 },
    objects: [
      { placeholder: { options: { name: 'title', type: 'title', x: 0.8, y: 2.0, w: 7.6, h: 1.7, fontSize: 66, bold: true, color: C.background1, valign: 'top', align: 'left', margin: 0 }, text: '' } },
      { placeholder: { options: { name: 'body', type: 'body', x: 0.8, y: 3.85, w: 7.4, h: 1.9, fontSize: 22, color: C.background2, valign: 'top', align: 'left', margin: 0 }, text: '' } },
    ],
  });

  // ------------------------------------------------------------------ helpers
  const shadow = () => ({ type: 'outer', color: '1B2A6B', opacity: 0.14, blur: 10, offset: 3, angle: 90 });
  const phone = (s, name, x, y, h) => s.addImage({ path: `shots/${name}.png`, x, y, w: h / 2, h, altText: `AIy screen: ${name.replace(/_/g, ' ')}`, shadow: { type: 'outer', color: '000000', opacity: 0.35, blur: 14, offset: 5, angle: 90 } });
  const card = (s, x, y, w, h, name, fill) => s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.14, fill: { color: fill || C.background1 }, line: { color: fill || C.background1 }, shadow: fill ? undefined : shadow(), objectName: name });
  const dot = (s, n, x, y, d, name, fill, txt, size) => s.addText(String(n), { shape: pres.shapes.OVAL, x, y, w: d, h: d, align: 'center', valign: 'middle', fontSize: size || 16, bold: true, color: txt || C.background1, fill: { color: fill || C.accent1 }, line: { color: fill || C.accent1 }, margin: 0, objectName: name });
  const icoCircle = async (s, Icon, x, y, d, fill, name) => {
    s.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color: fill }, line: { color: fill }, objectName: name + ' circle' });
    s.addImage({ data: await icon(Icon), x: x + d * 0.25, y: y + d * 0.25, w: d * 0.5, h: d * 0.5, altText: name });
  };
  const text = (s, runs, x, y, w, h, o = {}) => s.addText(runs, Object.assign({ x, y, w, h, fontSize: 16, color: C.text1, valign: 'top', margin: 0, isTextBox: true, paraSpaceAfter: 6 }, o));
  const B = (t) => ({ text: t, options: { bold: true } });
  const steps = (s, items, x, y, w, rowH, d = 0.42) => items.forEach((it, i) => {
    dot(s, i + 1, x, y + i * rowH, d, 'Step ' + (i + 1));
    text(s, it, x + d + 0.22, y + i * rowH - 0.04, w - d - 0.22, rowH - 0.1, { valign: 'top', fontSize: 16 });
  });
  const note = (s, str, x, y, w, h) => { card(s, x, y, w, h, 'Note card', C.text2); text(s, str, x + 0.25, y + 0.12, w - 0.5, h - 0.24, { color: C.background1, fontSize: 15, valign: 'middle' }); };

  let n = 0;
  const slide = (layout, section, title, notes) => {
    const s = pres.addSlide({ masterName: layout, sectionTitle: section });
    if (title) s.addText(title, { placeholder: 'title' });
    s.addNotes(notes);
    n++;
    return s;
  };

  // ================================================================== 1 title
  pres.addSection({ title: 'Start' });
  let s = slide('DARK', 'Start', null, 'Welcome. AIy is an app on your phone that chats, builds apps from an idea, and changes apps you already have. This guide shows each step with screens from the app. The screens in this deck are illustrations drawn from the app\'s layout; replace them with real screenshots from your phone if you prefer.');
  s.addText('AIy', { placeholder: 'title' });
  s.addText([{ text: 'Your AI assistant that chats, builds apps and fixes code', options: { breakLine: true } }, { text: 'A simple guide for first-time users', options: { fontSize: 16, color: C.accent6 } }], { placeholder: 'body' });
  phone(s, 'chat_home', 9.35, 0.65, 6.2);

  // ================================================================== 2 three jobs
  s = slide('CONTENT_WIDE', 'Start', 'AIy has three jobs', 'Chat, Build and Code are the three buttons at the top of the app. You need a phone, internet and one Google account. You do not need to know programming.');
  const jobs = [
    [fa.FaComments, C.accent1, 'Chat', 'Ask questions, get help writing, or have a photo or a document explained.'],
    [fa.FaHammer, C.accent2, 'Build', 'Describe an app you want. AIy asks questions, then writes the app for you.'],
    [fa.FaCode, C.accent3, 'Code', 'Already have an app? Say what should change and AIy changes it.'],
  ];
  for (let i = 0; i < 3; i++) {
    const x = 0.6 + i * 4.15;
    card(s, x, 1.85, 3.8, 3.3, 'Job card ' + (i + 1));
    await icoCircle(s, jobs[i][0], x + 0.35, 2.15, 0.95, jobs[i][1], jobs[i][2]);
    text(s, jobs[i][2], x + 0.35, 3.35, 3.1, 0.55, { fontSize: 28, bold: true, color: C.text2 });
    text(s, jobs[i][3], x + 0.35, 3.95, 3.1, 1.3, { fontSize: 16 });
  }
  note(s, [B('You need: '), { text: 'a phone, internet and one Google account. No programming knowledge.' }], 0.6, 5.55, 12.1, 0.9);

  // ================================================================== 3 install & sign in
  s = slide('CONTENT', 'Start', 'Install and sign in', 'Install the file you were given. If Android asks, allow installing from the app you opened the file from. Then tap Continue with Google. One Google account is all you need.');
  steps(s, [
    [B('Install '), { text: 'the AIy file you were given. If Android asks, allow "Install unknown apps" for the app you opened it from.' }],
    [B('Open AIy '), { text: 'and tap ' }, B('Continue with Google'), { text: '.' }],
    [B('Connect '), { text: 'your free AI accounts on the next screen (next slide).' }],
  ], 0.6, 1.9, 8.2, 1.15);
  note(s, [B('Good to know: '), { text: 'free plans may use what you type to improve their AI. Never type passwords or private secrets. Your keys stay encrypted on your phone.' }], 0.6, 5.35, 8.2, 1.3);
  phone(s, 'signin', 9.5, 0.65, 6.2);

  // ================================================================== 4 connect
  s = slide('CONTENT', 'Start', 'Connect your free AI accounts', 'Use the same Google account everywhere. A green tick means a service works. You can change any of this later in Settings, Accounts and keys.');
  const rows = [
    ['Gemini', 'The free main brain', 'Tap Get my free key, copy the key, come back. AIy finds it by itself.', C.accent1],
    ['OpenRouter', 'Writes apps and code', 'Tap Connect, choose Continue with Google, tap Authorize.', C.accent2],
    ['Groq', 'Optional fast backup', 'Same as Gemini.', C.accent6],
    ['GitHub', 'Optional, builds your app', 'Tap Connect, type the short code on the GitHub page.', C.accent6],
  ];
  rows.forEach((r, i) => {
    const y = 1.85 + i * 1.12;
    card(s, 0.6, y, 8.3, 0.98, 'Service row ' + (i + 1));
    s.addText(r[0], { shape: pres.shapes.ROUNDED_RECTANGLE, rectRadius: 0.1, x: 0.8, y: y + 0.2, w: 1.7, h: 0.58, fill: { color: r[3] }, line: { color: r[3] }, color: C.background1, bold: true, fontSize: 16, align: 'center', valign: 'middle', margin: 0, objectName: 'Service name ' + (i + 1) });
    text(s, [B(r[1])], 2.75, y + 0.12, 6.0, 0.32, { fontSize: 15, color: C.text2, paraSpaceAfter: 0 });
    text(s, r[2], 2.75, y + 0.45, 6.0, 0.5, { fontSize: 14, paraSpaceAfter: 0 });
  });
  text(s, [B('Then tap Start using AIy. '), { text: 'To change anything later: Settings, Accounts and keys.' }], 0.6, 6.4, 8.3, 0.5, { fontSize: 14, color: C.accent6 });
  phone(s, 'connect', 9.5, 0.65, 6.2);

  // ================================================================== 5 chat
  pres.addSection({ title: 'Chat' });
  s = slide('CONTENT', 'Chat', 'Chat: ask anything', 'Type your question and tap the arrow. The small label under the answer shows which AI wrote it. The four numbered buttons are explained on the left. Press and hold your own message to edit it and ask again.');
  const legend = [['1', 'Add a photo, or a file (a text file or a PDF)'], ['2', 'Choose which AI answers first'], ['3', 'Live internet search, for news and today\'s facts'], ['4', 'Speak instead of typing']];
  legend.forEach((l, i) => {
    dot(s, l[0], 0.6, 1.9 + i * 0.82, 0.46, 'Legend ' + l[0], C.accent4, C.text2, 17);
    text(s, l[1], 1.3, 1.95 + i * 0.82, 7.4, 0.5, { fontSize: 18, valign: 'middle' });
  });
  card(s, 0.6, 5.35, 8.3, 1.3, 'Tip card');
  text(s, [B('Under each answer: '), { text: 'copy, ask again, hear it read aloud, share. ' }, B('Press and hold '), { text: 'your own message to change it and ask again.' }], 0.9, 5.5, 7.7, 1.0, { fontSize: 16, valign: 'middle' });
  phone(s, 'chat_answer', 9.5, 0.65, 6.2);

  // ================================================================== 6 chat examples
  s = slide('CONTENT_WIDE', 'Chat', 'Five things to try in Chat', 'Each card is something you can type or do right now. For the document example, only Gemini can read PDFs. Always check important facts about health, money or legal matters with a real person.');
  const ex = [
    [fa.FaLightbulb, C.accent1, 'Learn something', 'Explain how the internet works in simple words.'],
    [fa.FaPen, C.accent2, 'Write a message', 'Help me write a polite message asking to move a meeting to tomorrow.'],
    [fa.FaCamera, C.accent3, 'Understand a letter', 'Tap +, take a photo of it, then ask: What is this asking me to do, and by when?'],
    [fa.FaGlobe, C.accent1, 'Today\'s facts', 'Switch on the globe, then ask: What are the most important news stories today?'],
    [fa.FaFilePdf, C.accent2, 'Summarize a document', 'Tap +, attach a PDF, then ask: Summarize this in 5 points. (Gemini reads PDFs.)'],
  ];
  for (let i = 0; i < 5; i++) {
    const x = 0.6 + (i % 3) * 4.15, y = 1.8 + Math.floor(i / 3) * 2.6;
    card(s, x, y, 3.8, 2.4, 'Example card ' + (i + 1));
    await icoCircle(s, ex[i][0], x + 0.3, y + 0.28, 0.62, ex[i][1], ex[i][2]);
    text(s, [B(ex[i][2])], x + 1.1, y + 0.33, 2.55, 0.55, { fontSize: 18, color: C.text2, valign: 'middle' });
    text(s, [{ text: ex[i][3], options: { italic: true } }], x + 0.3, y + 1.1, 3.25, 1.2, { fontSize: 15 });
  }
  note(s, [B('Always check important facts '), { text: 'about health, money or legal matters with a real person.' }], 0.6 + 2 * 4.15, 4.4, 3.8, 2.4);

  // ================================================================== 7 build overview
  pres.addSection({ title: 'Build' });
  s = slide('CONTENT_WIDE', 'Build', 'Build: from an idea to an app in 7 steps', 'These are the seven steps. Your ideas are saved: you can leave at any step and continue from Your apps and ideas in the Build tab.');
  const bs = [
    ['Start', 'Open the Build tab and tap Start a new app.'],
    ['Explain', 'Write your idea and choose how many questions AIy asks.'],
    ['Look', 'Pick a name, an icon style and colours.'],
    ['Answer', 'Tap a suggestion, type your own, or tap You decide.'],
    ['Brief', 'Read the plan. Change words, untick screens.'],
    ['Model', 'Pick who writes the code and see the cost first.'],
    ['Done', 'Save the zip, or publish to GitHub and build the app.'],
  ];
  bs.forEach((b, i) => {
    const x = 0.6 + (i % 4) * 3.07, y = 1.8 + Math.floor(i / 4) * 2.55;
    card(s, x, y, 2.85, 2.3, 'Build step card ' + (i + 1));
    dot(s, i + 1, x + 0.28, y + 0.28, 0.52, 'Build step ' + (i + 1), i === 6 ? C.accent3 : C.accent1, null, 20);
    text(s, [B(b[0])], x + 0.95, y + 0.3, 1.8, 0.5, { fontSize: 22, color: C.text2, valign: 'middle' });
    text(s, b[1], x + 0.28, y + 1.05, 2.4, 1.15, { fontSize: 15 });
  });
  card(s, 0.6 + 3 * 3.07, 4.35, 2.85, 2.3, 'Saved note', C.text2);
  text(s, [B('Your ideas are saved.'), { text: ' Leave at any step and continue later from "Your apps and ideas".' }], 0.6 + 3 * 3.07 + 0.28, 4.6, 2.4, 1.85, { color: C.background1, fontSize: 16 });

  // ================================================================== 8 explain + slider
  s = slide('CONTENT', 'Build', 'Explain your app and choose the number of questions', 'The text box is the place to explain your app. Simple words are fine, in any language. The slider chooses how many questions AIy asks, from 1 to 30. Five to ten is a good start; three to five for a first try.');
  text(s, [B('Say what it is for, who uses it and what it should do. '), { text: 'Simple words are fine, in any language. You can also speak it.' }], 0.6, 1.9, 8.2, 1.1, { fontSize: 18 });
  card(s, 0.6, 3.15, 3.95, 2.0, 'Stat card 1');
  text(s, [{ text: '1 to 30', options: { bold: true, fontSize: 40, color: C.accent1, breakLine: true } }, { text: 'questions: you choose the number with the slider' }], 0.9, 3.35, 3.4, 1.7, { fontSize: 15 });
  card(s, 4.85, 3.15, 3.95, 2.0, 'Stat card 2');
  text(s, [{ text: '5 to 10', options: { bold: true, fontSize: 40, color: C.accent2, breakLine: true } }, { text: 'a good start. Use 3 to 5 for a very first try.' }], 5.15, 3.35, 3.4, 1.7, { fontSize: 15 });
  text(s, [B('No idea yet? '), { text: 'Tap a ready idea: Habit tracker, Expense log, Quiz game, Shopping list, Notes or Countdown.' }], 0.6, 5.5, 8.2, 1.1, { fontSize: 16 });
  phone(s, 'build_describe', 9.5, 0.65, 6.2);

  // ================================================================== 9 look + questions
  s = slide('CONTENT_NARROW', 'Build', 'Pick the look, then answer the questions', 'The look screen sets the name, icon and colours of the finished app. Then AIy asks questions one at a time. You can tap a suggested answer, type or speak your own, tap You decide, or go Back.');
  card(s, 0.6, 1.85, 5.8, 2.2, 'Look card');
  text(s, [B('The look'), { text: ' Type a name (or tap Suggest). Pick an icon style, a colour and Auto, Light or Dark. The finished app gets all of it, even its icon.' }], 0.9, 2.0, 5.2, 1.95, { fontSize: 16, valign: 'middle' });
  card(s, 0.6, 4.25, 5.8, 2.4, 'Questions card');
  text(s, [B('The questions'), { text: ' One at a time. Tap a suggestion, type or speak your own answer, or tap You decide and AIy chooses. Back returns to the question before.' }], 0.9, 4.4, 5.2, 2.15, { fontSize: 16, valign: 'middle' });
  phone(s, 'build_look', 6.95, 0.8, 5.9); phone(s, 'build_question', 10.0, 0.8, 5.9);

  // ================================================================== 10 brief + model
  s = slide('CONTENT_NARROW', 'Build', 'Read the brief, then choose who writes the code', 'The brief is a short plan of your app. You can change any words and untick screens you do not want in the first version. The cost is shown before anything is spent, and it can never go above your limit.');
  card(s, 0.6, 1.85, 5.8, 1.55, 'Brief card');
  text(s, [B('The brief'), { text: ' is the plan of your app in plain words. Change anything. Untick a screen to leave it out.' }], 0.9, 1.95, 5.2, 1.35, { fontSize: 15, valign: 'middle' });
  card(s, 0.6, 3.55, 5.8, 1.7, 'Model card');
  text(s, [B('The model'), { text: ' writes the code. You see the estimated cost first. It never goes above your limit (the starting limit is $0.25 per request).' }], 0.9, 3.65, 5.2, 1.5, { fontSize: 15, valign: 'middle' });
  card(s, 0.6, 5.4, 5.8, 1.25, 'Check card');
  text(s, [B('Then AIy checks the code'), { text: ' and asks the model to fix problems, up to two more times.' }], 0.9, 5.45, 5.2, 1.15, { fontSize: 15, valign: 'middle' });
  phone(s, 'build_brief', 6.95, 0.8, 5.9); phone(s, 'build_write', 10.0, 0.8, 5.9);

  // ================================================================== 11 example
  s = slide('CONTENT', 'Build', 'Example: a habit tracker in 4 questions', 'This example shows what you type or tap at each step. The cost and file count are examples. The finished app is a small Flutter app with three screens.');
  const hdr = (t) => ({ text: t, options: { bold: true, color: C.background1, fill: { color: C.text2 }, fontSize: 14 } });
  const cell = (t, b) => ({ text: t, options: { bold: !!b, fontSize: 14, color: C.text1, fill: { color: C.background1 } } });
  s.addTable([
    [hdr('Step'), hdr('What you do')],
    [cell('Idea', 1), cell('Write: "A habit tracker. I add daily habits, tick them off each day, and see how many days in a row I did them." Slider: 4.')],
    [cell('Look', 1), cell('Name: Streaks. Icon: Spark. Colours: Aurora. Dark.')],
    [cell('Question 1', 1), cell('Who will use the app? Tap: Just me.')],
    [cell('Question 2', 1), cell('When you miss a day? Tap: The streak starts again.')],
    [cell('Question 3', 1), cell('Which screens? Type: A list of today\'s habits and a page with my streaks.')],
    [cell('Question 4', 1), cell('Should it remind you? Tap: You decide.')],
    [cell('Result', 1), cell('The brief lists 3 screens. AIy writes the app: 9 files, ready to publish.')],
  ], { x: 0.6, y: 1.8, w: 8.3, colW: [1.55, 6.75], border: { type: 'solid', color: C.background2, pt: 1 }, margin: [0.07, 0.12, 0.07, 0.12], valign: 'middle', objectName: 'Example table' });
  phone(s, 'build_done', 9.5, 0.65, 6.2);

  // ================================================================== 12 publish
  pres.addSection({ title: 'Publish' });
  s = slide('CONTENT', 'Publish', 'Turn it into a real phone app', 'GitHub builds the app file for free. Push first, optionally run the quick check, then build. The version you choose is written into the app. Later builds raise the build number by themselves, so they install over the old one.');
  steps(s, [
    [B('Push to GitHub. '), { text: 'For a new app, create a new repository and keep it Private.' }],
    [B('Quick check '), { text: '(optional): about 2 minutes, tests that the code compiles.' }],
    [B('Build the app. '), { text: 'AIy asks "Which version is this?" Pick one, such as 1.0.1.' }],
    [B('Wait about 5 minutes. '), { text: 'You can leave AIy. A notification tells you when it ends.' }],
    [B('Tap Install. '), { text: 'The first time, Android asks you to allow it once.' }],
    [B('Next versions '), { text: 'install over the old one and keep your data.' }],
  ], 0.6, 1.8, 8.3, 0.82);
  phone(s, 'version', 9.5, 0.65, 6.2);

  // ================================================================== 13 watch + share
  s = slide('CONTENT_NARROW', 'Publish', 'Watch the build, then install and share', 'The build screen shows each step. When it finishes you can install, save, share, open the release page or show a QR code. If the build fails, AIy shows the errors and can fix and rebuild automatically.');
  card(s, 0.6, 1.85, 5.8, 2.35, 'Share card');
  text(s, [B('Share it'), { text: ' Tap Share to send the file by message or email. Or open the Release page or QR code so others can scan it. Private repositories need a GitHub sign-in.' }], 0.9, 1.95, 5.2, 2.15, { fontSize: 15, valign: 'middle' });
  card(s, 0.6, 4.4, 5.8, 2.25, 'Fail card');
  text(s, [B('If the build fails'), { text: ' tap Fix and rebuild automatically. Choose a model and 1 to 3 tries. The cost is shown first, and AIy stops if the same error returns twice.' }], 0.9, 4.5, 5.2, 2.05, { fontSize: 15, valign: 'middle' });
  phone(s, 'build_progress', 6.95, 0.8, 5.9); phone(s, 'build_ready', 10.0, 0.8, 5.9);

  // ================================================================== 14 code
  pres.addSection({ title: 'Code' });
  s = slide('CONTENT', 'Code', 'Code: change an app you already have', 'Use the Code tab when an app already exists. You describe the change in plain words and AIy changes only the files that need it. Every change is kept in History, where you can go back to an older version.');
  steps(s, [
    [B('Upload a project zip '), { text: '(up to 100 MB), or open a GitHub repository.' }],
    [B('Write what should change. '), { text: 'You can speak it, or add a photo of the problem.' }],
    [B('Tap Find the files '), { text: 'and check the list.' }],
    [B('Pick the model, '), { text: 'read the cost, tap Write the change.' }],
    [B('Tap a file '), { text: 'to see the change: green added, red removed.' }],
    [B('Save the new zip, '), { text: 'or publish to GitHub and build.' }],
  ], 0.6, 1.8, 8.3, 0.82);
  phone(s, 'code', 9.5, 0.65, 6.2);

  // ================================================================== 15 code examples
  s = slide('CONTENT_WIDE', 'Code', 'Four changes to try in Code', 'Each card is a request you can type. Ask for one thing at a time: it is cheaper, faster and easier to check. The Ask about it button answers questions and changes nothing.');
  const ce = [
    [fa.FaPlusCircle, C.accent1, 'A new feature', 'Add a dark mode switch to the settings page.'],
    [fa.FaCamera, C.accent2, 'Fix what you can see', 'Add a photo of the screen, then write: The Save button text is cut off on small phones. Make it fit.'],
    [fa.FaPen, C.accent3, 'Change a word', 'Change the app name shown under the icon to Family Budget.'],
    [fa.FaQuestionCircle, C.accent1, 'Understand first', 'Tap Ask about it, then ask: Where is the data saved?'],
  ];
  for (let i = 0; i < 4; i++) {
    const x = 0.6 + (i % 2) * 6.15, y = 1.8 + Math.floor(i / 2) * 2.2;
    card(s, x, y, 5.95, 2.0, 'Code example ' + (i + 1));
    await icoCircle(s, ce[i][0], x + 0.3, y + 0.3, 0.7, ce[i][1], ce[i][2]);
    text(s, [B(ce[i][2])], x + 1.2, y + 0.3, 4.5, 0.5, { fontSize: 20, color: C.text2, valign: 'middle' });
    text(s, [{ text: ce[i][3], options: { italic: true } }], x + 1.2, y + 0.9, 4.5, 1.1, { fontSize: 15 });
  }
  note(s, [B('Tip: '), { text: 'ask for one thing at a time. Small changes are cheaper, faster and easier to check.' }], 0.6, 6.25, 12.1, 0.62);

  // ================================================================== 16 control
  pres.addSection({ title: 'Help' });
  s = slide('CONTENT', 'Help', 'Stay in control', 'Everything here is in Settings: tap your round picture at the top right. The spending limit caps one request. The app lock has no forgot-PIN button, so save a backup. Sign out and remove all keys before lending your phone.');
  const ctl = [
    [fa.FaCoins, C.accent1, 'Spending limit', 'Set the most one request can cost. Free models cost nothing. Spending shows this month, per app.'],
    [fa.FaLock, C.accent2, 'App lock', 'A PIN of 4 to 8 digits, plus the fingerprint. There is no "forgot PIN": save a backup.'],
    [fa.FaSave, C.accent3, 'Backup', 'One file with chats, ideas, history and settings. Keys are never in it.'],
  ];
  for (let i = 0; i < 3; i++) {
    const y = 1.8 + i * 1.5;
    card(s, 0.6, y, 8.3, 1.32, 'Control row ' + (i + 1));
    await icoCircle(s, ctl[i][0], 0.9, y + 0.3, 0.72, ctl[i][1], ctl[i][2]);
    text(s, [B(ctl[i][2])], 1.9, y + 0.12, 6.8, 0.4, { fontSize: 18, color: C.text2, paraSpaceAfter: 0 });
    text(s, ctl[i][3], 1.9, y + 0.55, 6.8, 0.75, { fontSize: 14, paraSpaceAfter: 0 });
  }
  note(s, [B('Before lending your phone: '), { text: 'Settings, then Sign out and remove all keys.' }], 0.6, 6.35, 8.3, 0.55);
  phone(s, 'settings', 9.5, 0.65, 6.2);

  // ================================================================== 17 trouble
  s = slide('CONTENT', 'Help', 'If something goes wrong', 'Start with Settings, Help, Test everything. It checks each part and shows a green, yellow or red line in plain words. Copy the report and send it to the person who gave you the app. The report has no keys in it.');
  text(s, [B('First: '), { text: 'Settings, Help, Test everything. Tap Copy the report and send it to the person who gave you the app.' }], 0.6, 1.75, 8.3, 0.8, { fontSize: 16 });
  const fix = [
    ['The key was rejected', 'Settings, Accounts and keys, tap Replace.'],
    ['The limit is used up for now', 'Wait. AIy moves to the next service by itself.'],
    ['No AI service could answer', 'Check your internet, then run Test everything.'],
    ['GitHub says 403 or 404', 'Disconnect GitHub, then connect it again.'],
    ['The build failed', 'Tap Fix and rebuild automatically.'],
    ['"App not installed"', 'Uninstall the old copy once, then install the new one.'],
  ];
  s.addTable([[hdr('What you see'), hdr('What to do')], ...fix.map((f) => [cell(f[0], 1), cell(f[1])])], { x: 0.6, y: 2.7, w: 8.3, colW: [3.1, 5.2], border: { type: 'solid', color: C.background2, pt: 1 }, margin: [0.07, 0.12, 0.07, 0.12], valign: 'middle', objectName: 'Trouble table' });
  phone(s, 'test', 9.5, 0.65, 6.2);

  // ================================================================== 18 dictionary
  s = slide('CONTENT_WIDE', 'Help', 'Small dictionary', 'These are the words used in this guide, in plain language.');
  const dict = [
    ['Key', 'A secret code, like a password, that lets AIy use an AI service.'],
    ['Model', 'One AI brain. Better ones write better apps and can cost a little.'],
    ['Token', 'A small piece of text. AI services charge by the token.'],
    ['Brief', 'The short written plan of your app, made from your answers.'],
    ['Repository', 'One project stored on GitHub.'],
    ['Push', 'Send your changes to GitHub.'],
    ['APK', 'The app file you install on an Android phone.'],
    ['Version', 'The number the app shows, such as 1.0.1. It rises with each build.'],
  ];
  dict.forEach((d, i) => {
    const x = 0.6 + (i % 4) * 3.07, y = 1.85 + Math.floor(i / 4) * 2.45;
    card(s, x, y, 2.85, 2.25, 'Word card ' + (i + 1));
    text(s, [B(d[0])], x + 0.28, y + 0.25, 2.3, 0.5, { fontSize: 24, color: i % 2 ? C.accent2 : C.accent1, paraSpaceAfter: 0 });
    text(s, d[1], x + 0.28, y + 0.9, 2.35, 1.25, { fontSize: 15 });
  });

  // ================================================================== 19 closing
  s = slide('DARK', 'Help', null, 'Start small. A small app that works is better than a big one that does not. You can always add more later with the Code tab.');
  s.addText('Start small', { placeholder: 'title' });
  s.addText([
    { text: 'Try one small app with 3 to 5 questions.', options: { bullet: true, breakLine: true } },
    { text: 'Check the cost line before every paid request.', options: { bullet: true, breakLine: true } },
    { text: 'Save a backup after anything you care about.', options: { bullet: true } },
  ], { placeholder: 'body', paraSpaceAfter: 10 });
  phone(s, 'chat_home', 9.35, 0.65, 6.2);

  await pres.writeFile({ fileName: 'AIy-simple-guide.pptx' });
  await applyTheme('AIy-simple-guide.pptx', THEME);
  console.log('slides:', n);
})().catch((e) => { console.error(e); process.exit(1); });
