/// Ready-made app ideas for the Build tab: one tap fills the description and a sensible number of questions.
library;

class Starter {
  final String title;
  final String idea;
  final int count;
  const Starter(this.title, this.idea, this.count);
}

const List<Starter> kStarters = [
  Starter('Habit tracker', 'A habit tracker. I add daily habits, tick them off each day, and see my streak (days in a row) and a simple weekly chart. Everything stays on my phone.', 4),
  Starter('Expense log', 'An expense log for my family. I add what we spent with an amount, a category and a note, and see the total per day and per month and which category costs the most.', 5),
  Starter('Quiz game', 'A quiz game for kids. It asks multiple-choice questions about a topic I choose, shows right or wrong after each answer, shows the final score, and remembers the best score.', 5),
  Starter('Shopping list', 'A shopping list. I add items with a quantity and a category, tick them off in the shop and clear the ticked ones. Items are grouped by category.', 3),
  Starter('Notes', 'A notes app. I write notes with a title and text, pin the important ones, search them, and can undo a delete.', 3),
  Starter('Countdown', 'A countdown app. I add events with a date and see how many days are left, nearest first. Past events show how long ago they were.', 3),
];
